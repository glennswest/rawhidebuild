#!/bin/bash
# Build Fedora Rawhide dev ISO with CloudID integration
# Runs as an mkube job on the build-runner pool
set -euo pipefail

WORK_DIR="/data/rawhidebuild"
CLOUDID_URL="http://192.168.200.20:8090"
MKUBE_API="http://192.168.200.2:8082"
CDROM_NAME="rawhide-dev"
ISO_NAME="${CDROM_NAME}.iso"

echo "=== Fedora Rawhide Dev ISO Builder ==="
echo "CloudID: ${CLOUDID_URL}"
echo "mkube:   ${MKUBE_API}"

mkdir -p "${WORK_DIR}"

# --- Step 1: Install build tools ---
echo "--- Installing build tools ---"
dnf install -y lorax curl jq

# --- Step 2: Download Rawhide boot.iso ---
RAWHIDE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/images/boot.iso"
BOOT_ISO="${WORK_DIR}/boot.iso"

if [ ! -f "${BOOT_ISO}" ]; then
    echo "--- Downloading Rawhide boot.iso ---"
    curl -L -o "${BOOT_ISO}" "${RAWHIDE_URL}"
else
    echo "--- Using cached boot.iso ---"
fi

# --- Step 3: Create kickstart ---
KS="${WORK_DIR}/cloudid.ks"
cat > "${KS}" << 'KSEOF'
# Fedora Rawhide Dev — CloudID Integration
# Embedded kickstart — fetches SSH keys from CloudID at install time

# Install from Fedora Rawhide repos
url --url=https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/

# System config
lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --enabled --ssh

# Network — DHCP
network --bootproto=dhcp --device=link --activate

# Root password locked — SSH key access only
rootpw --lock

# Disk — wipe sda
zerombr
clearpart --all --initlabel --drives=sda
autopart --type=plain

# Bootloader
bootloader --location=mbr --boot-drive=sda

# Services
services --enabled=sshd,chronyd

# Reboot after install
reboot

%packages
@core
@standard
@development-tools
openssh-server
openssh-clients
chrony
vim-enhanced
tmux
git
rsync
htop
curl
wget
jq
strace
ltrace
perf
bpftrace
rust
cargo
rustfmt
clippy
rust-src
rust-std-static
golang
golang-bin
gcc
gcc-c++
clang
llvm
lld
cmake
meson
ninja-build
autoconf
automake
libtool
pkgconf
kernel-devel
kernel-headers
kernel-modules-extra
elfutils-libelf-devel
dwarves
bc
flex
bison
openssl-devel
ncurses-devel
sparse
cscope
ctags
glibc-devel
glibc-static
musl-libc
musl-gcc
liburing-devel
iscsi-initiator-utils
zlib-devel
libffi-devel
sqlite-devel
bzip2-devel
xz-devel
readline-devel
%end

%post --log=/root/ks-post.log
#!/bin/bash
set -ex

# Enable root SSH login
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Fetch SSH keys from CloudID
CLOUDID="http://192.168.200.20:8090"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
KEYS=""
for idx in $(curl -sf "${CLOUDID}/latest/meta-data/public-keys/" 2>/dev/null | grep -oP '^\d+' || true); do
    K=$(curl -sf "${CLOUDID}/latest/meta-data/public-keys/${idx}/openssh-key" 2>/dev/null || true)
    [ -n "$K" ] && KEYS="${KEYS}${K}\n"
done
if [ -n "$KEYS" ]; then
    echo -e "$KEYS" | sort -u > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi
restorecon -R /root/.ssh 2>/dev/null || true

# CloudID SSH key refresh timer
cat > /etc/systemd/system/cloudid-keys.service << 'SVCEOF'
[Unit]
Description=Refresh SSH keys from CloudID
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'KEYS=""; for idx in $(curl -sf http://192.168.200.20:8090/latest/meta-data/public-keys/ 2>/dev/null | grep -oP "^\\d+"); do K=$(curl -sf http://192.168.200.20:8090/latest/meta-data/public-keys/$idx/openssh-key 2>/dev/null); [ -n "$K" ] && KEYS="$KEYS\n$K"; done; if [ -n "$KEYS" ]; then mkdir -p /root/.ssh; echo -e "$KEYS" | sort -u > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; fi'
SVCEOF

cat > /etc/systemd/system/cloudid-keys.timer << 'TMREOF'
[Unit]
Description=Refresh SSH keys from CloudID every 5 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
TMREOF

systemctl enable cloudid-keys.timer

# Install rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source /root/.cargo/env
rustup target add x86_64-unknown-linux-musl
rustup target add aarch64-unknown-linux-musl
rustup component add rust-src rust-analyzer

# Dev environment paths
cat > /etc/profile.d/dev-paths.sh << 'ENVEOF'
export GOPATH=/root/go
export PATH=$PATH:/root/go/bin:/root/.cargo/bin
ENVEOF

systemctl enable sshd
echo "CloudID post-install complete"
%end
KSEOF

# --- Step 4: Build ISO with embedded kickstart ---
echo "--- Building ISO with mkksiso ---"
mkksiso \
    --cmdline "inst.ks=file:///run/install/ks.cfg console=tty0 console=ttyS0,115200 console=ttyS1,115200 ip=dhcp" \
    "${KS}" \
    "${BOOT_ISO}" \
    "${WORK_DIR}/${ISO_NAME}"

echo "--- ISO built ---"
ls -lh "${WORK_DIR}/${ISO_NAME}"

# --- Step 5: Create iSCSI CDROM in mkube ---
echo "--- Creating iSCSI CDROM: ${CDROM_NAME} ---"

# Delete existing if present
curl -sf -X DELETE "${MKUBE_API}/api/v1/iscsi-cdroms/${CDROM_NAME}" 2>/dev/null || true
sleep 2

# Create CDROM object
curl -sf -X POST "${MKUBE_API}/api/v1/iscsi-cdroms" \
    -H 'Content-Type: application/json' \
    -d "{
        \"metadata\": {\"name\": \"${CDROM_NAME}\"},
        \"spec\": {
            \"isoFile\": \"${ISO_NAME}\",
            \"description\": \"Fedora Rawhide dev workstation with Go, Rust, kernel dev tools + CloudID SSH\",
            \"readOnly\": true
        }
    }"
echo ""

# --- Step 6: Upload ISO to mkube ---
echo "--- Uploading ISO to mkube ---"
curl -f -X POST "${MKUBE_API}/api/v1/iscsi-cdroms/${CDROM_NAME}/upload" \
    -F "iso=@${WORK_DIR}/${ISO_NAME}"
echo ""

# --- Step 7: Verify ---
echo "--- Verifying CDROM ---"
curl -sf "${MKUBE_API}/api/v1/iscsi-cdroms/${CDROM_NAME}" | jq '{name: .metadata.name, phase: .status.phase, size: .status.isoSize, iqn: .status.targetIQN}'

echo ""
echo "=== Build complete ==="
echo "To boot server2 from this ISO:"
echo "  mk patch bmh/server2 --type=merge -p '{\"spec\":{\"image\":\"${CDROM_NAME}\"}}'"
echo "  mk annotate bmh/server2 bmh.mkube.io/reboot=\$(date -u +%Y-%m-%dT%H:%M:%SZ) --overwrite"
