#!/bin/bash -eu
set -o pipefail

sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io golang

for lv in home tmp var; do
  sudo lvextend -r -L +10G /dev/mapper/rootvg-${lv}lv
done

mkdir -p ~/go/bin
PATH=$HOME/go/bin:$PATH

tar xf tec-src.tgz
pushd operator

go install github.com/mikefarah/yq/v4
go install sigs.k8s.io/kind

KUBEADM_CONFIG=$(cat <<EOF
kind: ClusterConfiguration
apiServer:
  certSANs:
    - "0.0.0.0"
    - "$1"
EOF
)
KIND_IMAGE=$(awk '/kindest/ {print $NF}' Cargo.toml)
export KUBEADM_CONFIG KIND_IMAGE
yq -i '.networking.apiServerAddress = "0.0.0.0" |
       .networking.apiServerPort = 6443 |
       .nodes[0].image = env(KIND_IMAGE) |
       .nodes[0].kubeadmConfigPatches[0] = strenv(KUBEADM_CONFIG)' kind/config.yaml

# Tests' k8s interaction comes from Prow host, but kubectl is required for some cluster setup extras
k8s_version=$(cut -d: -f2 <<< "$KIND_IMAGE")
sudo curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/${k8s_version}/bin/linux/amd64/kubectl"
sudo chmod +x /usr/local/bin/kubectl

sudo usermod -aG docker "$(whoami)"
sudo mkdir -p /etc/docker
echo '{"insecure-registries": ["localhost:5000"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl start docker
