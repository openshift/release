#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
target_bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

# Check if target bastion is in maintenance mode
if ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${bastion}" root@${target_bastion} 'test -f /root/pause'; then
  echo "The cluster is on maintenance mode. Remove the file /root/pause in the bastion host when the maintenance is over"
  exit 1
fi

CRUCIBLE_URL=$(cat ${CLUSTER_PROFILE_DIR}/crucible_url)
JETLAG_PR=${JETLAG_PR:-}
REPO_NAME=${REPO_NAME:-}
PULL_NUMBER=${PULL_NUMBER:-}
KUBECONFIG_SRC=""
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD
if [[ "$NUM_WORKER_NODES" == "" ]]; then
  NUM_WORKER_NODES=$(cat ${CLUSTER_PROFILE_DIR}/config | jq ".num_worker_nodes")
  export NUM_WORKER_NODES
fi
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE
LOGIN=$(cat "${CLUSTER_PROFILE_DIR}/login")
export LOGIN

echo "Starting deployment on lab $LAB, cloud $LAB_CLOUD ..."

echo "Removing bastion self-reference from resolv.conf ..."
ssh ${SSH_ARGS} root@${bastion} "sed -i '\$!{/^nameserver/d}' /etc/resolv.conf"

cat <<EOF >>/tmp/all.yml
---
lab: $LAB
lab_cloud: $LAB_CLOUD
cluster_type: $TYPE
worker_node_count: $NUM_WORKER_NODES
public_vlan: $PUBLIC_VLAN
sno_use_lab_dhcp: false
enable_fips: $FIPS
ssh_private_key_file: ~/.ssh/id_rsa
ssh_public_key_file: ~/.ssh/id_rsa.pub
pull_secret: "{{ lookup('file', '../pull_secret.txt') }}"
smcipmitool_url: "file:///root/smcipmitool.tar.gz"
bastion_cluster_config_dir: /root/{{ cluster_type }}
setup_bastion_gogs: false
setup_bastion_registry: false
use_bastion_registry: false
install_rh_crucible: $CRUCIBLE
rh_crucible_url: "$CRUCIBLE_URL"
payload_url: "${RELEASE_IMAGE_LATEST}"
image_type: "minimal-iso"
EOF

if [[ $PUBLIC_VLAN == "false" ]]; then
  echo "Private network deployment"
  echo -e "enable_bond: $BOND" >> /tmp/all.yml
  echo -e "controlplane_network: 192.168.216.1/21\ncontrolplane_network_prefix: 21" >> /tmp/all.yml

  # Create proxy configuration for private VLAN deployments
  cat > ${SHARED_DIR}/proxy-conf.sh << 'PROXY_EOF'
#!/bin/bash

cleanup_ssh() {
  # Kill the SOCKS proxy running on the jumphost
  ssh ${SSH_ARGS} root@${jumphost} "pkill -f 'ssh root@${bastion} -fNT -D'" 2>/dev/null || true
  # Kill local SSH processes
  pkill ssh
}

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

# Generate a random port between 10000-65535 for SOCKS proxy
SOCKS_PORT=$((RANDOM % 55536 + 10000))

# Step 1: Start SOCKS proxy on jumphost connecting to bastion (runs in background on jumphost)
ssh ${SSH_ARGS} root@${jumphost} "ssh root@${bastion} -fNT -D 0.0.0.0:${SOCKS_PORT}" &

# Step 2: Forward the SOCKS proxy from jumphost back to CI host
ssh ${SSH_ARGS} root@${jumphost} -fNT -L ${SOCKS_PORT}:localhost:${SOCKS_PORT}

# Give SSH tunnels a moment to establish
sleep 3

# Configure proxy settings for oc commands
export KUBECONFIG=${SHARED_DIR}/kubeconfig
export https_proxy=socks5://localhost:${SOCKS_PORT}
export http_proxy=socks5://localhost:${SOCKS_PORT}

# Configure oc to use the proxy
oc --kubeconfig=${SHARED_DIR}/kubeconfig config set-cluster "$(oc config current-context)" --proxy-url=socks5://localhost:${SOCKS_PORT}

trap 'cleanup_ssh' EXIT
PROXY_EOF
fi

if [[ "$TYPE" == "vmno" ]]; then
  # Load VMNO configuration from cluster profile
  HV_COUNT=$(cat ${CLUSTER_PROFILE_DIR}/config | jq -r ".hv_count")
  HV_VM_CPU_COUNT=$(cat ${CLUSTER_PROFILE_DIR}/config | jq -r ".hv_vm_cpu_count")
  HV_VM_MEMORY_SIZE=$(cat ${CLUSTER_PROFILE_DIR}/config | jq -r ".hv_vm_memory_size")
  HV_VM_DISK_SIZE=$(cat ${CLUSTER_PROFILE_DIR}/config | jq -r ".hv_vm_disk_size")

  # Extract hardware model from bastion hostname
  HV_HW_NAME=$(cat ${CLUSTER_PROFILE_DIR}/bastion | cut -d'.' -f1 | awk -F'-' '{print $NF}')

  # Convert hv_vm_disk JSON to YAML format with proper indentation
  HV_VM_DISK_YAML=$(cat ${CLUSTER_PROFILE_DIR}/config | jq -r '.hv_vm_disk | to_entries | map("      " + .key + ": " + (.value | tostring)) | join("\n")')

  cat <<EOF >>/tmp/all.yml
hv_ssh_pass: $LOGIN
hv_ip_offset: 0
hv_vm_ip_offset: 20
compact_cluster_dns_count: 0
standard_cluster_dns_count: 0
hv_count: $HV_COUNT
hv_vm_cpu_count: $HV_VM_CPU_COUNT
hv_vm_memory_size: $HV_VM_MEMORY_SIZE
hv_vm_disk_size: $HV_VM_DISK_SIZE
hw_vm_counts:
  $LAB:
    $HV_HW_NAME:
$HV_VM_DISK_YAML
EOF
fi

if [[ "$TYPE" == "hmno" ]]; then
  cat <<EOF >>/tmp/all.yml
hybrid_worker_count: $NUM_HYBRID_WORKER_NODES
hv_ip_offset: 0
hv_vm_ip_offset: 36
hv_inventory: true
compact_cluster_dns_count: 0
standard_cluster_dns_count: 0
hv_ssh_pass: $LOGIN
cluster_type: mno
EOF
  cat <<EOF >>/tmp/hv.yml
install_tc: false
lab: $LAB
ssh_public_key_file: ~/.ssh/id_rsa.pub
use_bastion_registry: false
setup_hv_vm_dhcp: false
compact_cluster_dns_count: 0
standard_cluster_dns_count: 0
hv_vm_generate_manifests: false
sno_cluster_count: 0
EOF
fi

if [[ "$TYPE" == "vmno" ]]; then
  cat <<EOF >>/tmp/hv.yml
install_tc: true
lab: $LAB
ssh_public_key_file: ~/.ssh/id_rsa.pub
use_bastion_registry: false
setup_coredns: false
setup_hv_vm_dhcp: false
compact_cluster_dns_count: 0
standard_cluster_dns_count: 0
hv_vm_generate_manifests: false
sno_cluster_count: 0
EOF
fi

echo "This is the final all.yml file:"
cat /tmp/all.yml

envsubst < /tmp/all.yml > /tmp/all-updated.yml

# Copy the ssh key to the bastion host
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
bastion2=$(curl -sSk $OCPINV | jq -r ".nodes[0].name")
ssh ${SSH_ARGS} root@${bastion} "
   ssh-keygen -R ${bastion2}
   sshpass -p $LOGIN ssh-copy-id -o StrictHostKeyChecking=no root@${bastion2}
"

# Clean up previous attempts
cat > /tmp/clean-resources.sh << 'EOF'
echo 'Running clean-resources.sh'
dnf install -y podman
podman pod stop $(podman pod ps -q) || echo 'No podman pods to stop'
podman pod rm $(podman pod ps -q)   || echo 'No podman pods to delete'
podman stop $(podman ps -aq)        || echo 'No podman containers to stop'
podman rm $(podman ps -aq)          || echo 'No podman containers to delete'
rm -rf /opt/*

# Find connection that owns the default gateway
default_gw_conn=$(
  nmcli -t -f NAME,DEVICE connection show --active |
    grep "$(ip route | awk '/default/ {print $5; exit}')" |
    cut -d: -f1
)
# Read active connection names safely into an array
readarray -t conns < <(nmcli -t -f NAME connection show --active)
# Loop and delete all except the default one
for c in "${conns[@]}"; do
  if [[ "$c" != "$default_gw_conn" && "$c" != "lo" && "$c" != "cni-podman0" ]]; then
    echo "Deleting: $c"
    nmcli connection delete "$c"
  fi
done
EOF

# Override JETLAG_BRANCH to main when JETLAG_LATEST is true
if [[ ${JETLAG_LATEST} == 'true' ]]; then
  JETLAG_BRANCH=main
fi

# Setup Bastion
jetlag_repo=/tmp/jetlag-${LAB}-${LAB_CLOUD}-$(date +%s)
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   git clone https://github.com/redhat-performance/jetlag.git --depth=1 --branch=${JETLAG_BRANCH:-main} ${jetlag_repo}
   cd ${jetlag_repo}
   # JETLAG_PR or PULL_NUMBER can't be set at the same time
   if [[ -n '${JETLAG_PR}' ]]; then
     git pull origin pull/${JETLAG_PR}/head:${JETLAG_PR} --rebase
     git switch ${JETLAG_PR}
   elif [[ -n '${PULL_NUMBER}' ]] && [[ '${REPO_NAME}' == 'jetlag' ]]; then
     git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
     git switch ${PULL_NUMBER}
   fi
   git branch
   source bootstrap.sh
"
# Save jetlag_repo for next Step(s) that may need this info
echo $jetlag_repo > ${SHARED_DIR}/jetlag_repo

cp ${CLUSTER_PROFILE_DIR}/pull_secret /tmp/pull-secret
oc registry login --to=/tmp/pull-secret

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${bastion}:${jetlag_repo}/ansible/vars/all.yml
scp -q ${SSH_ARGS} /tmp/pull-secret root@${bastion}:${jetlag_repo}/pull_secret.txt
scp -q ${SSH_ARGS} /tmp/clean-resources.sh root@${bastion}:/tmp/

if [[ "$TYPE" == "hmno" || "$TYPE" == "vmno" ]]; then
  scp -q ${SSH_ARGS} /tmp/hv.yml root@${bastion}:${jetlag_repo}/ansible/vars/hv.yml
fi


if [[ ${TYPE} == 'sno' ]]; then
  KUBECONFIG_SRC='/root/sno/{{ groups.sno[0] }}/kubeconfig'
elif [[ ${TYPE} == 'hmno' ]]; then
  KUBECONFIG_SRC=/root/mno/kubeconfig
else
  KUBECONFIG_SRC=/root/${TYPE}/kubeconfig
fi

collect_ai_logs() {
  echo "Collecting AI logs ..."
  ssh ${SSH_ARGS} root@${bastion} "
    AI_CLUSTER_ID=\$(curl -sS http://$bastion2:8080/api/assisted-install/v2/clusters/  | jq -r .[0].id)
    echo 'Cluster ID is:' \$AI_CLUSTER_ID
    mkdir -p /tmp/ai-logs/$LAB/$LAB_CLOUD/$TYPE
    curl -LsSo /tmp/ai-logs/$LAB/$LAB_CLOUD/$TYPE/ai-cluster-logs.tar http://$bastion2:8080/api/assisted-install/v2/clusters/\$AI_CLUSTER_ID/logs
    rm -rf /tmp/ai-logs/$LAB/$LAB_CLOUD/$TYPE/ai-cluster-logs.tar.gz
    gzip /tmp/ai-logs/$LAB/$LAB_CLOUD/$TYPE/ai-cluster-logs.tar
  "
  scp -q ${SSH_ARGS} root@${bastion}:/tmp/ai-logs/$LAB/$LAB_CLOUD/$TYPE/ai-cluster-logs.tar.gz ${ARTIFACT_DIR}
}

trap 'collect_ai_logs' EXIT

ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${jetlag_repo}
   source .ansible/bin/activate
   ansible-playbook ansible/create-inventory.yml | tee /tmp/ansible-create-inventory-$(date +%s)
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m script -a /tmp/clean-resources.sh
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/setup-bastion.yml | tee /tmp/ansible-setup-bastion-$(date +%s)
   if [[ \"$TYPE\" == \"hmno\" || \"$TYPE\" == \"vmno\" ]]; then
     export ANSIBLE_HOST_KEY_CHECKING=False
     ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/hv-setup.yml -v | tee /tmp/ansible-hv-setup-$(date +%s)
     ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/hv-vm-create.yml -v | tee /tmp/ansible-hv-vm-create-$(date +%s)
   fi
   if [[ \"$TYPE\" == \"hmno\" || \"$TYPE\" == \"vmno\" ]]; then
     ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/mno-deploy.yml -v | tee /tmp/ansible-mno-deploy-$(date +%s)
   else
     ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/${TYPE}-deploy.yml -v | tee /tmp/ansible-${TYPE}-deploy-$(date +%s)
   fi
   mkdir -p /root/$LAB/$LAB_CLOUD/$TYPE
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m fetch -a 'src=${KUBECONFIG_SRC} dest=/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig flat=true'
   deactivate
   rm -rf .ansible
"

scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig ${SHARED_DIR}/kubeconfig
