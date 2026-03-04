#!/bin/bash -eu
set -o pipefail

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1"
}

log_success() {
  echo "[SUCCESS] $1"
}

if [ -z "${SHARED_DIR}" ]; then
  log_error "SHARED_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

repository=github.com/trusted-execution-clusters/operator
src_dir=/go/src/$repository
if [ ! -d $src_dir ]; then
  log_info "No existing checkout (presumed rehearsal PR), creating checkout"
  mkdir -p /go/src
  git clone https://$repository $src_dir
  log_success "Checked out $repository"
fi
pushd /go/src/$repository/..

rpm --import https://packages.microsoft.com/keys/microsoft.asc
dnf install -y https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm
dnf install -y azure-cli cargo g++ jq rustfmt

log_info "Setup an ephemeral Azure VM for a Kind cluster"
secret_base=/var/run/azure-upstream-ci
test_id=$(uuidgen | cut -d- -f1)

az_region=eastus
az_resource_group=upstream-ci-$test_id
echo "$az_resource_group" > "$SHARED_DIR/az-resource-group"
kind_vm_user=ci
kind_vm_name=kind-vm
kind_vm_image=$(grep KIND_HOST_URN operator/Makefile | cut -d= -f2 | tr -d ' ')
vm_size=Standard_D2s_v3

AZURE_SUBSCRIPTION_ID=$(cat $secret_base/subscription-id)
export AZURE_SUBSCRIPTION_ID
az login --service-principal \
  --username "$(cat $secret_base/client-id)" \
  --password "$(cat $secret_base/client-secret)" \
  --tenant "$(cat $secret_base/tenant-id)"

log_info "Create Azure resource group $az_resource_group"
az group create \
  --location $az_region \
  --resource-group "$az_resource_group"
log_info "Create Azure VM $kind_vm_name of image $kind_vm_image"
kind_vm_ip=$(az vm create \
  --name $kind_vm_name \
  --resource-group "$az_resource_group" \
  --size $vm_size \
  --image "$kind_vm_image" \
  --admin-username $kind_vm_user \
  --generate-ssh-keys | jq -r .publicIpAddress)
log_success "Created Azure VM $kind_vm_name (public IP $kind_vm_ip), waiting for availability"
az vm wait --created \
  --name $kind_vm_name \
  --resource-group "$az_resource_group"

SSHOPTS=(
  -o ConnectTimeout=30
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

ssh "${SSHOPTS[@]}" $kind_vm_user@"$kind_vm_ip" echo
log_success "Azure VM $kind_vm_name has SSH access"

log_info "Open ports on Azure VM"
nsg=$(az vm show \
  --resource-group "$az_resource_group" \
  --name $kind_vm_name \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | \
  xargs az network nic show --query "networkSecurityGroup.id" -o tsv --ids | \
  cut -d/ -f9)
ports=(6443 8000 8080)
for i in "${!ports[@]}"; do
  port=${ports[$i]}
  az network nsg rule create \
    --resource-group "$az_resource_group" \
    --nsg-name "$nsg" \
    --name "allow-$port" \
    --priority $((1001 + i)) \
    --source-address-prefixes "*" \
    --destination-port-ranges "$port" \
    --protocol Tcp \
    --access Allow \
    --direction Inbound
done
log_success "Opened ports on Azure VM"

log_info "Transfer source to Azure VM"
src_tarball=tec-src.tgz
tar czf $src_tarball operator
# shellcheck disable=SC2029
scp "${SSHOPTS[@]}" $src_tarball $kind_vm_user@"$kind_vm_ip":~
popd
provision=$(mktemp)
cat > "$provision" << 'PROVISION'
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
PROVISION
chmod +x "$provision"
scp "${SSHOPTS[@]}" "$provision" $kind_vm_user@"$kind_vm_ip":~/provision.sh
rm "$provision"

log_info "Prepare Kind cluster on Azure VM"
log_warn "kind/config.yaml has some custom modifications applied. Refer to openshift/release repository for details."
# shellcheck disable=SC2029
ssh "${SSHOPTS[@]}" ${kind_vm_user}@"$kind_vm_ip" "\$HOME/provision.sh $kind_vm_ip"
log_success "Prepare Kind cluster on Azure VM"

log_info "Create Kind cluster on Azure VM"
ssh "${SSHOPTS[@]}" ${kind_vm_user}@"$kind_vm_ip" "cd \$HOME/operator && PATH=\$HOME/go/bin:\$PATH RUNTIME=docker make cluster-up"

pushd /go/src/$repository
make yq
kubeconf=~/.kube/config
mkdir -p ~/.kube
scp "${SSHOPTS[@]}" $kind_vm_user@"$kind_vm_ip":~/.kube/config $kubeconf
# shellcheck disable=SC2211
bin/yq* -i ".clusters[0].cluster.server = \"https://$kind_vm_ip:6443\"" $kubeconf
kubectl get pods
log_success "Created Kind cluster on Azure VM"

log_info "Build operator images on Azure VM"
ssh "${SSHOPTS[@]}" ${kind_vm_user}@"$kind_vm_ip" "cd \$HOME/operator && CONTAINER_CLI=docker REGISTRY=localhost:5000 make -j2 push"
log_success "Built & pushed operator images"

log_info "Run integration tests"
eval "$(ssh-agent)"
PLATFORM=kind_public VIRT_PROVIDER=azure REGISTRY=localhost:5000 \
  TEST_NAMESPACE_PREFIX="$az_resource_group-" \
  TEST_IMAGE=$(cat $secret_base/test-image) \
  CLUSTER_URL="$kind_vm_ip" \
  make integration-tests
log_success "Ran integration tests"
