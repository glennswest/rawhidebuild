#!/bin/bash
# CloudID first-boot integration
# Fetches SSH keys from CloudID metadata endpoint and sets up periodic refresh
set -euo pipefail

CLOUDID_URL="http://192.168.200.20:8090"
STAMP="/var/lib/cloudid-firstboot.stamp"

[ -f "$STAMP" ] && exit 0

echo "CloudID first-boot: fetching SSH keys..."

# Fetch root SSH keys from CloudID metadata
KEYS=$(curl -sf "$CLOUDID_URL/latest/meta-data/public-keys/" 2>/dev/null || true)
if [ -n "$KEYS" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    # Fetch each key index
    for idx in $(echo "$KEYS" | grep -oP '^\d+'); do
        KEY=$(curl -sf "$CLOUDID_URL/latest/meta-data/public-keys/$idx/openssh-key" 2>/dev/null || true)
        if [ -n "$KEY" ]; then
            echo "$KEY" >> /root/.ssh/authorized_keys.tmp
        fi
    done
    if [ -f /root/.ssh/authorized_keys.tmp ]; then
        sort -u /root/.ssh/authorized_keys.tmp > /root/.ssh/authorized_keys
        rm -f /root/.ssh/authorized_keys.tmp
        chmod 600 /root/.ssh/authorized_keys
        restorecon -R /root/.ssh 2>/dev/null || true
        echo "CloudID: installed $(wc -l < /root/.ssh/authorized_keys) SSH keys for root"
    fi
fi

# Harden SSH
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null || true

# Install rustup for full Rust toolchain
if ! command -v rustup &>/dev/null; then
    echo "CloudID: installing rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source /root/.cargo/env
    rustup target add x86_64-unknown-linux-musl
    rustup target add aarch64-unknown-linux-musl
    rustup component add rust-src rust-analyzer
fi

# Set up Go and Rust paths
cat > /etc/profile.d/dev-paths.sh << 'ENVEOF'
export GOPATH=/root/go
export PATH=$PATH:/root/go/bin:/root/.cargo/bin
ENVEOF

touch "$STAMP"
echo "CloudID first-boot complete"
