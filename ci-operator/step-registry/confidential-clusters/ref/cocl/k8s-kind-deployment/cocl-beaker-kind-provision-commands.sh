#!/bin/bash
set -e

echo "=== Installing prerequisites ==="
# dnf is idempotent. It will only install or update packages if necessary.
# Added jq to parse kubectl version information.
sudo dnf install -y curl gcc make dnf-plugins-core wget tar git jq

echo "=== Installing Rust via rustup (Official Method) ==="
if ! command -v rustc &> /dev/null; then
    echo "Rust not found. Installing via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
else
    echo "Rust is already installed: $(rustc --version)"
    echo "Updating rustup and toolchains..."
    # Source the env to ensure rustup is in the PATH for the update command
    source "$HOME/.cargo/env"
    rustup update
fi

# Add Rust to the system-wide PATH for all users. This ensures that 'cargo'
# is available in subsequent steps and non-interactive sessions.
RUST_PROFILE_SCRIPT="/etc/profile.d/rust.sh"
if ! [ -f "${RUST_PROFILE_SCRIPT}" ]; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' | sudo tee "${RUST_PROFILE_SCRIPT}"
fi

# Source the new profile script to make Rust available in the current session
source "${RUST_PROFILE_SCRIPT}"
rustc --version
cargo --version

echo "=== Installing Docker CE and Podman ==="
# Create Docker CE repo manually (Fedora 42 compatible)
sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
EOF

# Install both Docker and Podman to allow the user to choose the runtime.
sudo dnf install -y docker-ce docker-ce-cli containerd.io podman

# systemctl is idempotent. It will only start/enable services if they are not already running/enabled.
sudo systemctl enable --now docker
sudo systemctl enable --now podman.socket
docker --version
podman --version

echo "=== Installing kubectl ==="
K8S_VERSION="v1.29.0" # Pinned version
INSTALLED_K8S_VERSION=""
if command -v kubectl &> /dev/null; then
    # Extract version, handle potential errors if kubectl is broken
    INSTALLED_K8S_VERSION=$(kubectl version --client -o=json 2>/dev/null | jq -r .clientVersion.gitVersion || echo "unknown")
fi

if [[ "${INSTALLED_K8S_VERSION}" == "${K8S_VERSION}" ]]; then
    echo "kubectl is already installed at the desired version (${K8S_VERSION})."
else
    echo "Installing kubectl version ${K8S_VERSION}..."
    curl -Lo ./kubectl "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi
kubectl version --client

echo "=== Installing kind ==="
KIND_VERSION="v0.30.0"
if [[ "$(kind version -q 2>/dev/null)" == "${KIND_VERSION}" ]]; then
    echo "kind is already installed at the desired version (${KIND_VERSION})."
else
    echo "Installing kind version ${KIND_VERSION}..."
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x kind
    sudo mv kind /usr/local/bin/
fi
kind version

echo "=== Installing Go ==="
# Install Go using dnf. dnf is idempotent and will install or update if necessary.
sudo dnf install -y golang
go version

echo "=== Install virtualization packages ==="
sudo dnf install -y libvirt libvirt-daemon-kvm qemu-kvm yq

echo "=== Start libvirt services ==="
for drv in qemu network storage;
do
       systemctl start virt${drv}d.socket
       systemctl start virt${drv}d-ro.socket
done
virsh net-list --all

echo "=== All tools installed successfully ==="

