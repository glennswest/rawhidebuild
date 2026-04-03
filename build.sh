#!/bin/bash
set -euo pipefail

MKUBE_API="http://192.168.200.2:8082"
CDROM_NAME="rawhideinstall"
ISO_NAME="rawhideinstall.iso"
WORK="/data/rawhidebuild"
RAWHIDE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/images/boot.iso"
RAWHIDE_REPO="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/"

# Install build tools
echo "=== Installing build tools ==="
dnf install -y lorax jq xorriso createrepo_c dnf-plugins-core

mkdir -p "$WORK"

# Download Rawhide boot.iso
if [ ! -f "$WORK/boot.iso" ]; then
    echo "=== Downloading Rawhide boot.iso ==="
    curl -L -o "$WORK/boot.iso" "$RAWHIDE_URL"
else
    echo "=== Using cached boot.iso ==="
fi

# Write kickstart — uses cdrom as install source (packages on disc)
echo "=== Writing kickstart ==="
cat > "$WORK/cloudid.ks" << 'KSEOF'
# Install source set via kernel param: inst.repo=hd:LABEL=<volid>

# Disable online repos — boot.iso is netinstall, its repos point to mirrors.
# All packages are on the ISO; no internet required.
repo --name=fedora --baseurl=file:///run/install/repo --cost=1
repo --name=fedora-updates --baseurl=file:///run/install/repo --cost=1

lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --enabled --ssh
network --bootproto=dhcp --device=link --activate
rootpw --plaintext "rawhide"
sshkey --username=root "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDWUsb0I159v27vSBuOOyQMX54iD2zuKZOOy+e5GRCJ3yONNr3Mkdyng67BNfsnvlf8kpgSi0yiaVGeXKSjkrY9YPHe0wkVW0UHZ9uZqYqgVdEzSG3Z0NNkrd/zp3jCztPad+q6iWb1R0iFlK7/h8NihOky9HXOustrtDwnvTgONwJnluxQp1zl86deKP0W9xx3Ky/Jobr3dbfOhJVK3qzF6OL6KaNjpT+hDYjh1OISzrx1jWLxFvZ4r7X2wbRhcNRyD5sTrxcs3z5Xdz/KRT0UhIj47CF4Heoiqtl/aQ5kdjpRqlmC2spJ9WZinsqbb6HhZ1i8Yd2ZycDQZF+S8n1n gwest@Glenns-MacBook-Pro.local"
zerombr
clearpart --all --initlabel --drives=sda
autopart --type=plain
bootloader --location=mbr --boot-drive=sda --append="earlycon=uart8250,io,0x2f8,115200n8 console=tty0 console=ttyS1,115200n8 console=ttyS0,115200n8"
services --enabled=sshd,chronyd
reboot

%packages --ignoremissing
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
systemctl enable serial-getty@ttyS0.service
systemctl enable serial-getty@ttyS1.service

# Configure GRUB for serial on the installed system
cat > /etc/default/grub.d/serial-console.cfg << 'GRUBEOF'
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --unit=1 --speed=115200"
GRUBEOF
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

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

# Signal mkube that install is complete — switches BMH to localboot
# so the server boots from disk on next reboot instead of reinstalling
curl -sf -X POST "http://192.168.200.2:8082/api/v1/boot-complete" && echo "Switched to localboot" || echo "WARNING: Failed to signal boot-complete"
%end
KSEOF

# === Download all packages for offline DVD ===
echo "=== Downloading all RPMs for offline DVD ==="
PKGDIR="$WORK/Packages"
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR"

# Use dnf install --downloadonly with a temporary installroot.
# This is the only reliable way to resolve @group packages on dnf5 —
# it uses the full dependency solver with proper group expansion.
INSTALLROOT="$WORK/installroot"
rm -rf "$INSTALLROOT"

# Explicit packages from kickstart (non-group packages)
EXTRA_PKGS=$(sed -n '/%packages/,/%end/{/%packages/d;/%end/d;/^#/d;/^$/d;/^@/d;p}' "$WORK/cloudid.ks" | tr '\n' ' ')

# Groups from kickstart
GROUPS=$(sed -n '/%packages/,/%end/{/%packages/d;/%end/d;/^#/d;/^$/d;/^@/p}' "$WORK/cloudid.ks" | tr '\n' ' ')

# Anaconda hardware-detected requirements (not in @core/@standard)
EXTRA_PKGS="$EXTRA_PKGS grub2 grub2-tools grub2-tools-minimal grub2-tools-extra grub2-pc shim-x64 grub2-efi-x64 efibootmgr iscsi-initiator-utils NetworkManager firewalld sudo dracut-config-rescue kernel"

echo "Groups: $GROUPS"
echo "Extra packages: $EXTRA_PKGS"

echo "=== Resolving and downloading all packages via installroot ==="
dnf install -y --downloadonly \
    --installroot="$INSTALLROOT" \
    --repofrompath=rawhide,"$RAWHIDE_REPO" \
    --repo=rawhide \
    --releasever=rawhide \
    --setopt=keepcache=1 \
    --skip-unavailable \
    $GROUPS $EXTRA_PKGS

# Collect all downloaded RPMs from the dnf cache inside installroot
echo "=== Collecting RPMs from installroot cache ==="
find "$INSTALLROOT" -name '*.rpm' -exec cp {} "$PKGDIR/" \;

# If installroot cache was empty, check host cache as fallback
if [ "$(ls "$PKGDIR"/*.rpm 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "WARNING: No RPMs in installroot cache, checking host cache"
    find /var/cache/libdnf5 /var/cache/dnf -name '*.rpm' 2>/dev/null -exec cp {} "$PKGDIR/" \;
fi

rm -rf "$INSTALLROOT"

echo "=== Downloaded $(ls "$PKGDIR"/*.rpm 2>/dev/null | wc -l) RPMs ==="
du -sh "$PKGDIR"

# Download comps.xml (group definitions) from Rawhide repo
echo "=== Downloading comps.xml for package group definitions ==="
REPOMD_URL="${RAWHIDE_REPO}repodata/repomd.xml"
COMPS_HREF=$(curl -sf "$REPOMD_URL" | grep -oP 'href="[^"]*comps[^"]*\.xml(\.gz|\.xz|\.zst)?' | head -1 | sed 's/href="//')
if [ -n "$COMPS_HREF" ]; then
    echo "Found comps file: $COMPS_HREF"
    curl -L --retry 3 -o "$WORK/comps-raw" "${RAWHIDE_REPO}${COMPS_HREF}"
    # Decompress if needed
    case "$COMPS_HREF" in
        *.gz)  gunzip -c "$WORK/comps-raw" > "$WORK/comps.xml" ;;
        *.xz)  xz -dc "$WORK/comps-raw" > "$WORK/comps.xml" ;;
        *.zst) zstd -dc "$WORK/comps-raw" > "$WORK/comps.xml" ;;
        *)     mv "$WORK/comps-raw" "$WORK/comps.xml" ;;
    esac
    echo "comps.xml size: $(wc -c < "$WORK/comps.xml") bytes"
    COMPS_ARG="-g $WORK/comps.xml"
else
    echo "WARNING: Could not find comps.xml in repo metadata"
    COMPS_ARG=""
fi

# === Build the DVD ISO ===
echo "=== Building DVD ISO ==="
EXTRACT="$WORK/isoextract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"

# Extract boot.iso
xorriso -osirrox on -indev "$WORK/boot.iso" -extract / "$EXTRACT"
chmod -R u+w "$EXTRACT"

# Copy kickstart and packages into ISO tree
cp "$WORK/cloudid.ks" "$EXTRACT/ks.cfg"
cp -a "$PKGDIR" "$EXTRACT/Packages"

# Create repo metadata at ISO root level — paths in metadata will include
# "Packages/" prefix so DNF finds RPMs at /Packages/*.rpm, not at /*.rpm
echo "=== Creating repository metadata at ISO root ==="
rm -rf "$EXTRACT/repodata"
createrepo_c $COMPS_ARG "$EXTRACT"

# Create .treeinfo so Anaconda recognizes this as a DVD install tree
cat > "$EXTRACT/.treeinfo" << 'TREEEOF'
[general]
name = Fedora Rawhide
family = Fedora
version = rawhide
arch = x86_64
platforms = x86_64

[tree]
arch = x86_64
platforms = x86_64

[variant-Everything]
id = Everything
name = Everything
type = variant
packages = Packages
repository = .
TREEEOF

# Get original volume ID
ORIG_VOLID=$(xorriso -indev "$WORK/boot.iso" -pvd_info 2>&1 | grep "Volume Id" | sed 's/.*: //' | tr -d "'" | xargs)
echo "Original Volume ID: $ORIG_VOLID"

# Patch every grub.cfg
for grubcfg in $(find "$EXTRACT" -name 'grub.cfg' 2>/dev/null); do
    echo "Patching $grubcfg"
    # Serial terminal
    sed -i '1i serial --unit=1 --speed=115200\nterminal_input serial console\nterminal_output serial console' "$grubcfg"
    # Auto-install: timeout 0, first entry
    sed -i 's/^set timeout=.*/set timeout=0/' "$grubcfg"
    sed -i 's/^set default=.*/set default="0"/' "$grubcfg"
    # rd.iscsi.firmware + ip=ibft: hand off iSCSI CDROM connection from iPXE to kernel
    # Keep original inst.stage2=hd:LABEL=... — label lookup finds the boot device
    # Use same LABEL for kickstart and repo (cdrom: prefix waits for /dev/sr* which doesn't exist)
    sed -i '/^\s*linux\|^\s*linuxefi/ s|$| rd.iscsi.firmware ip=ibft inst.ks=hd:LABEL='"$ORIG_VOLID"':/ks.cfg inst.repo=hd:LABEL='"$ORIG_VOLID"' earlycon=uart8250,io,0x2f8,115200n8 console=tty0 console=ttyS1,115200n8 console=ttyS0,115200n8|' "$grubcfg"
    # Remove media check and quiet
    sed -i 's/ rd.live.check//g' "$grubcfg"
    sed -i 's/ quiet//g' "$grubcfg"
    echo "--- Patched grub.cfg ---"
    cat "$grubcfg"
    echo "--- end ---"
done

# Build ISO using xorriso modify mode — preserves original boot structure
echo "=== Building final ISO with xorriso (modify mode) ==="

# Build map args: kickstart, packages, repodata, and patched grub.cfgs
MAP_ARGS="-map $EXTRACT/ks.cfg /ks.cfg"
MAP_ARGS="$MAP_ARGS -map $EXTRACT/.treeinfo /.treeinfo"
MAP_ARGS="$MAP_ARGS -map $EXTRACT/Packages /Packages"
MAP_ARGS="$MAP_ARGS -map $EXTRACT/repodata /repodata"
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
    -d "{\"metadata\":{\"name\":\"$CDROM_NAME\"},\"spec\":{\"isoFile\":\"$ISO_NAME\",\"description\":\"Fedora Rawhide DVD + CloudID SSH\",\"readOnly\":true}}"
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
