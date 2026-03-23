#!/bin/bash
set -euo pipefail

MKUBE_API="http://192.168.200.2:8082"
CDROM_NAME="rawhide-dev-$(date +%Y%m%d%H%M)"
ISO_NAME="${CDROM_NAME}.iso"
WORK="/data/rawhidebuild"
RAWHIDE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/images/boot.iso"

# Install build tools
if ! command -v mkksiso &>/dev/null; then
    echo "=== Installing lorax (mkksiso) ==="
    dnf install -y lorax jq
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
@c-development

# SSH & system
openssh-server
openssh-clients
chrony
vim-enhanced
neovim
tmux
git
git-lfs
git-email
gh
tig
rsync
htop
curl
wget
jq
yq
tree
zsh
ripgrep
fd-find
bat
fzf
ShellCheck
diffutils
patch

# Kernel development — core
kernel-devel
kernel-headers
kernel-modules
kernel-modules-extra
glibc-devel
glibc-static
elfutils-libelf-devel
elfutils-devel
openssl-devel
dwarves
sparse
coccinelle
bc
bison
flex
ncurses-devel
perl
perl-devel
python3
python3-pip
python3-devel
cscope
ctags
kmod
kmod-devel

# Device driver subsystem headers
pciutils
pciutils-devel
usbutils
libusb1-devel
libpcap-devel
libdrm-devel
mesa-libGL-devel
mesa-libEGL-devel
libinput-devel
libevdev-devel
libudev-devel
systemd-devel

# Block/storage driver headers
lvm2-devel
device-mapper-devel
libblkid-devel
libaio-devel
liburing-devel
sg3_utils-devel
nvme-cli

# Network driver headers
libmnl-devel
libnl3-devel
libnfnetlink-devel
libnetfilter_conntrack-devel
ethtool
iw

# RDMA / InfiniBand
rdma-core-devel
libibverbs-devel

# NUMA
numactl-devel

# Sound/ALSA
alsa-lib-devel

# Crypto
libgcrypt-devel
nss-devel

# Firmware / ACPI
acpica-tools
i2c-tools

# Kernel debugging & tracing
perf
strace
ltrace
systemtap
systemtap-devel
crash
trace-cmd
bpftool
libbpf-devel
bcc-devel
bcc-tools
bpftrace

# Device tree (ARM kernel work)
dtc

# Firmware tools
pesign

# Kernel doc build
python3-sphinx
graphviz
texinfo

# C/C++ toolchain
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
ccache
make

# Rust (distro packages — rustup in %post)
rust
cargo
rustfmt
clippy
rust-src
rust-std-static
musl-libc
musl-gcc

# Go toolchain
golang
golang-misc

# Block device & filesystem tools
parted
gdisk
e2fsprogs
xfsprogs
btrfs-progs
dosfstools
squashfs-tools
mdadm
device-mapper-multipath
cryptsetup
iscsi-initiator-utils
sg3_utils
lsscsi
sdparm
hdparm
smartmontools
nbd
blktrace
fio
ioping

# Networking & debugging
bind-utils
iputils
iproute
nmap-ncat
socat
tcpdump
wireshark-cli

# Container & packaging
podman
buildah
skopeo
rpm-build
rpm-devel
rpmlint

# Libraries
zlib-devel
libffi-devel
sqlite-devel
bzip2-devel
xz-devel
readline-devel
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

# Install rustup with full toolchain
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile default
source /usr/local/cargo/env
rustup component add rust-src rust-analyzer clippy rustfmt
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
# Cargo tools
curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
cargo binstall -y cargo-watch cargo-expand cargo-audit sccache || true

# Go tools
export GOPATH=/root/go
mkdir -p "$GOPATH/src" "$GOPATH/bin" "$GOPATH/pkg"
go install golang.org/x/tools/gopls@latest || true
go install github.com/go-delve/delve/cmd/dlv@latest || true
go install honnef.co/go/tools/cmd/staticcheck@latest || true

# Python extras for kernel dev
pip3 install --no-cache-dir b4 codespell || true

# Dev paths
cat > /etc/profile.d/dev-paths.sh << 'ENVEOF'
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export GOPATH=/root/go
export PATH=$PATH:/root/go/bin:/usr/local/cargo/bin
ENVEOF

# Git defaults
git config --system init.defaultBranch main
git config --system pull.rebase true
git config --system core.autocrlf input
%end
KSEOF

# Build ISO with embedded kickstart
echo "=== Building ISO with xorriso ==="
dnf install -y xorriso 2>/dev/null || true

EXTRACT="$WORK/isoextract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"

# Extract the ISO
xorriso -osirrox on -indev "$WORK/boot.iso" -extract / "$EXTRACT"
chmod -R u+w "$EXTRACT"

# Copy kickstart into ISO root
cp "$WORK/cloudid.ks" "$EXTRACT/ks.cfg"

# Get the original volume ID (needed for inst.stage2=hd:LABEL=...)
ORIG_VOLID=$(xorriso -indev "$WORK/boot.iso" -pvd_info 2>&1 | grep "Volume Id" | sed 's/.*: //' | tr -d "'" | xargs)
echo "Original Volume ID: $ORIG_VOLID"

# Patch every grub.cfg found in the extracted tree
for grubcfg in $(find "$EXTRACT" -name 'grub.cfg' 2>/dev/null); do
    echo "Patching $grubcfg"
    # Add serial terminal at top
    sed -i '1i serial --unit=0 --speed=115200\nterminal_input serial console\nterminal_output serial console' "$grubcfg"
    # Timeout 0, default to first entry (Install, not Test media)
    sed -i 's/^set timeout=.*/set timeout=0/' "$grubcfg"
    sed -i 's/^set default=.*/set default="0"/' "$grubcfg"
    # Add kickstart + console to all kernel lines
    sed -i '/^\s*linux\|^\s*linuxefi/ s|$| inst.ks=cdrom:/ks.cfg console=tty0 console=ttyS0,115200 console=ttyS1,115200 ip=dhcp|' "$grubcfg"
    # Remove mediacheck (rd.live.check) so it goes straight to install
    sed -i 's/ rd.live.check//g' "$grubcfg"
    echo "--- Patched grub.cfg ---"
    cat "$grubcfg"
    echo "--- end ---"
done

# Rebuild ISO — map ALL modified files back, preserve boot structure and original volume ID
# Build map args for all patched grub.cfg files
MAP_ARGS="-map $EXTRACT/ks.cfg /ks.cfg"
for grubcfg in $(find "$EXTRACT" -name 'grub.cfg' 2>/dev/null); do
    REL_PATH="${grubcfg#$EXTRACT}"
    MAP_ARGS="$MAP_ARGS -map $grubcfg $REL_PATH"
    echo "Will map: $REL_PATH"
done

xorriso -indev "$WORK/boot.iso" \
    -outdev "$WORK/$ISO_NAME" \
    $MAP_ARGS \
    -boot_image any replay \
    -volid "$ORIG_VOLID" \
    -commit

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
echo "To boot a server from this ISO:"
echo "  mk patch bmh/<hostname> --type=merge -p '{\"spec\":{\"image\":\"${CDROM_NAME}\"}}'"
echo "  mk annotate bmh/<hostname> bmh.mkube.io/reboot=\$(date -u +%Y-%m-%dT%H:%M:%SZ) --overwrite"
