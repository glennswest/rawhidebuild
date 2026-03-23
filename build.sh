#!/bin/bash
set -euo pipefail

MKUBE_API="http://192.168.200.2:8082"
CDROM_NAME="rawhide-dev"
ISO_NAME="${CDROM_NAME}.iso"
WORK="/data/rawhidebuild"
RAWHIDE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/images/boot.iso"

# Install build tools
if ! command -v mkksiso &>/dev/null; then
    echo "=== Installing lorax (mkksiso) ==="
    dnf install -y lorax
fi

mkdir -p "$WORK"

# Download Rawhide boot.iso
if [ ! -f "$WORK/boot.iso" ]; then
    echo "=== Downloading Rawhide boot.iso ==="
    curl -L -o "$WORK/boot.iso" "$RAWHIDE_URL"
else
    echo "=== Using cached boot.iso ==="
fi

# Write kickstart
echo "=== Writing kickstart ==="
cat > "$WORK/cloudid.ks" << 'KSEOF'
url --url=https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/
lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --enabled --ssh
network --bootproto=dhcp --device=link --activate
rootpw --lock
zerombr
clearpart --all --initlabel --drives=sda
autopart --type=plain
bootloader --location=mbr --boot-drive=sda
services --enabled=sshd,chronyd
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
perf
bpftrace
rust
cargo
rustfmt
clippy
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
%end

%post --log=/root/ks-post.log
set -ex

# SSH config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Fetch SSH keys from CloudID at install time
CLOUDID="http://192.168.200.20:8090"
for idx in $(curl -sf "${CLOUDID}/latest/meta-data/public-keys/" 2>/dev/null | grep -oP '^\d+' || true); do
    curl -sf "${CLOUDID}/latest/meta-data/public-keys/${idx}/openssh-key" >> /root/.ssh/authorized_keys 2>/dev/null || true
done
[ -f /root/.ssh/authorized_keys ] && chmod 600 /root/.ssh/authorized_keys
restorecon -R /root/.ssh 2>/dev/null || true

# CloudID SSH key refresh timer
cat > /etc/systemd/system/cloudid-keys.service << 'SVCEOF'
[Unit]
Description=Refresh SSH keys from CloudID
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -sf http://192.168.200.20:8090/latest/meta-data/public-keys/ 2>/dev/null | grep -oP "^\\d+" | while read idx; do curl -sf "http://192.168.200.20:8090/latest/meta-data/public-keys/$idx/openssh-key"; done > /tmp/keys.tmp && [ -s /tmp/keys.tmp ] && mv /tmp/keys.tmp /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys || rm -f /tmp/keys.tmp'
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

systemctl enable cloudid-keys.timer sshd

# Install rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source /root/.cargo/env
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
rustup component add rust-src rust-analyzer

# Dev paths
cat > /etc/profile.d/dev-paths.sh << 'ENVEOF'
export GOPATH=/root/go
export PATH=$PATH:/root/go/bin:/root/.cargo/bin
ENVEOF
%end
KSEOF

# Build ISO with embedded kickstart
echo "=== Building ISO with mkksiso ==="
mkksiso \
    --cmdline "inst.ks=file:///run/install/ks.cfg console=tty0 console=ttyS0,115200 console=ttyS1,115200 ip=dhcp" \
    "$WORK/cloudid.ks" \
    "$WORK/boot.iso" \
    "$WORK/$ISO_NAME"

ls -lh "$WORK/$ISO_NAME"

# Push to mkube iSCSI CDROM
echo "=== Creating iSCSI CDROM: ${CDROM_NAME} ==="
curl -sf -X DELETE "$MKUBE_API/api/v1/iscsi-cdroms/$CDROM_NAME" 2>/dev/null || true
sleep 2

curl -sf -X POST "$MKUBE_API/api/v1/iscsi-cdroms" \
    -H 'Content-Type: application/json' \
    -d "{\"metadata\":{\"name\":\"$CDROM_NAME\"},\"spec\":{\"isoFile\":\"$ISO_NAME\",\"description\":\"Fedora Rawhide dev + CloudID SSH\",\"readOnly\":true}}"
echo ""

echo "=== Uploading ISO to mkube ==="
curl -f -X POST "$MKUBE_API/api/v1/iscsi-cdroms/$CDROM_NAME/upload" \
    -F "iso=@$WORK/$ISO_NAME"
echo ""

echo "=== Verifying ==="
curl -sf "$MKUBE_API/api/v1/iscsi-cdroms/$CDROM_NAME" | jq .status

echo ""
echo "=== Done! CDROM ready: ${CDROM_NAME} ==="
echo "Boot server2: mk patch bmh/server2 --type=merge -p '{\"spec\":{\"image\":\"${CDROM_NAME}\"}}'"
