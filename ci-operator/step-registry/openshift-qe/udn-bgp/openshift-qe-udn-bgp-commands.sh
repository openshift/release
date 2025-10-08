#!/bin/bash
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
   shellcheck disable=SC1090
   source "${SHARED_DIR}/proxy-conf.sh"
fi

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

# Patch network operator to enable FRR
PATCH_NETWORK_OPERATOR_SCRIPT="patch_network_operator_script.sh"
cat > $PATCH_NETWORK_OPERATOR_SCRIPT << 'EOF'
   export KUBECONFIG=/root/vmno/kubeconfig
   oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
EOF
chmod +x $PATCH_NETWORK_OPERATOR_SCRIPT
ssh ${SSH_ARGS} root@$bastion 'bash -s' < $PATCH_NETWORK_OPERATOR_SCRIPT
sleep 10
rm -f $PATCH_NETWORK_OPERATOR_SCRIPT
# Wait 30 minutes for FRR to be enabled
sleep 1800

LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD
echo "LAB is $LAB_CLOUD"
LOGIN=password


# This script is run on the bastion host. It sshs into the hypervisor creates a VM
# and then spawns external BGP server on the VM.
SCRIPT_FILE="remote_script.sh"
cat > $SCRIPT_FILE << 'EOF'
#!/bin/bash
set -x
LAB_CLOUD=$1
export KUBECONFIG=/root/vmno/kubeconfig
LOGIN=password
INVENTORY_FILE="/root/jetlag/ansible/inventory/$LAB_CLOUD.local"
CREATE_VM_SCRIPT="create_vm_script.sh"
PREPATE_SERVER_SCRIPT="prepare_server_script.sh"
source /root/jetlag/.ansible/bin/activate

# Get the list of hosts in the 'hv_vm' group
HOSTS=$(ansible-inventory -i "$INVENTORY_FILE" --list | jq -r '.hv_vm.hosts[]')

# Get the last host from the list
VM_NAME=$(echo "$HOSTS" | tail -n 1)

# Get the value of hv_ip for the last host
HV_IP=$(ansible-inventory -i "$INVENTORY_FILE" --host "$VM_NAME" | jq -r '.hv_ip')
VM_IP=$(ansible-inventory -i "$INVENTORY_FILE" --host "$VM_NAME" | jq -r '.ip')
GATEWAY_IP=$(ansible-inventory -i "$INVENTORY_FILE" --host "$VM_NAME" | jq -r '.gateway')

# Print the extracted value 
echo "The ip for the last entry is: $VM_NAME $HV_IP $VM_IP"
deactivate

SSH_ARGS='-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null'

#!/bin/bash

# Define the name of the script to be created
SOURCE_IMAGE="/var/lib/libvirt/images/rhel-guest-image.qcow2"
DEST_IMAGE="/mnt/disk2/libvirt/images/$VM_NAME.qcow2"

cat > $CREATE_VM_SCRIPT << _EOF_
#!/bin/bash

set -x

curl -k -o "$SOURCE_IMAGE" http://mirror.scalelab.redhat.com/RHEL9/9.6.0/BaseOS/x86_64/images/rhel-guest-image-9.6-20250408.20.x86_64.qcow2
qemu-img create -f qcow2 "$DEST_IMAGE" 120G

virt-resize --expand "/dev/sda3" "$SOURCE_IMAGE" "$DEST_IMAGE"

NAMESERVER=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}')

virt-customize -a "$DEST_IMAGE" --root-password password:"$LOGIN"
virt-customize -a "$DEST_IMAGE" \
 --run-command 'cat << __EOF__ > /etc/sysconfig/network-scripts/ifcfg-eth0
TYPE=Ethernet
BOOTPROTO=none
DEFROUTE=yes
IPADDR='$VM_IP'
PREFIX=24
GATEWAY='$GATEWAY_IP'
DNS1='$NAMESERVER'
ONBOOT=yes
NAME=eth0
__EOF__'

virsh start "$VM_NAME"
sleep 180
_EOF_

echo "Script '$CREATE_VM_SCRIPT' created. Now you can use it with SSH."

chmod +x $CREATE_VM_SCRIPT
ssh -i /root/.ssh/id_rsa ${SSH_ARGS} root@${HV_IP} 'bash -s' < $CREATE_VM_SCRIPT

ssh-keygen -R $VM_IP 2>/dev/null || true
ssh-keyscan $VM_IP >> ~/.ssh/known_hosts

# Copy hosts file and kubeconfig from bastion host
sshpass -p "$LOGIN" scp /root/vmno/kubeconfig root@$VM_IP:~/
sshpass -p "$LOGIN" scp /etc/hosts /etc/resolv.conf root@$VM_IP:/etc/

cat > $PREPATE_SERVER_SCRIPT << _EOF_
#!/bin/bash

set -x
cat << __EOF__ > /etc/yum.repos.d/RHEL96-AppStream.repo
[rhel96-appstream]
name=RHEL96 AppStream
baseurl=http://mirror.scalelab.redhat.com/RHEL9/9.6.0/AppStream/x86_64/os/
enabled=1
gpgcheck=0
__EOF__

# Create the RHEL96-BaseOS.repo file
cat << __EOF__ > /etc/yum.repos.d/RHEL96-BaseOS.repo
[rhel96-baseos]
name=RHEL96 BaseOS
baseurl=http://mirror.scalelab.redhat.com/RHEL9/9.6.0/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
__EOF__

dnf install curl git make binutils bison gcc glibc-devel golang podman jq -y
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz | tar -xvzf -
mv oc kubectl /usr/bin/
export KUBECONFIG=/root/kubeconfig

sysctl -w net.ipv4.ip_forward=1
sysctl -p

# Flush all existing nftables rules
sudo nft flush ruleset

# Create a temporary file with the new rules
cat << __EOF__ | sudo nft -f -
table ip filter {
  chain input {
    type filter hook input priority 0; policy accept;
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
__EOF__

git clone -b ovnk-bgp https://github.com/jcaamano/frr-k8s
cd frr-k8s/hack/demo;
./demo.sh
cd -
oc apply -n openshift-frr-k8s -f frr-k8s/hack/demo/configs/receive_all.yaml

podman exec -u root 'frr' vtysh -c '$(cat <<__EOF__
configure terminal
router bgp 64512
redistribute static
redistribute connected
end
write
__EOF__
)'

_EOF_
chmod +x $PREPATE_SERVER_SCRIPT
sshpass -p "$LOGIN" ssh ${SSH_ARGS} root@${VM_IP} 'bash -s' < $PREPATE_SERVER_SCRIPT
echo $VM_IP
EOF

chmod +x $SCRIPT_FILE
VM_IP=$(ssh ${SSH_ARGS} root@$bastion 'bash -s --' "$LAB_CLOUD" < $SCRIPT_FILE)
sleep 10
rm -f $SCRIPT_FILE

VARS_FILE="vars.sh"
cat > $VARS_FILE << EOF
export ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}
export ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
export ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
export ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    export ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

export REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
export LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
export TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
EOF

sshpass -p "$LOGIN" scp $VARS_FILE root@${VM_IP}:~/
sleep 10
rm -f $VARS_FILE

# Run the workload on the VM where external BGP server is running
RUN_WORKLOAD_SCRIPT="run_workload_script.sh"
cat > $RUN_WORKLOAD_SCRIPT << 'EOF'
#!/bin/bash

set -x
source /root/vars.sh
export KUBECONFIG=/root/kubeconfig

git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=udn-bgp
export ITERATIONS=72
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
./run.sh
sleep 10
rm -f /root/vars.sh
EOF

chmod +x $RUN_WORKLOAD_SCRIPT
sshpass -p "$LOGIN" ssh ${SSH_ARGS} root@${VM_IP} 'bash -s' < $RUN_WORKLOAD_SCRIPT
sleep 10
rm -f $RUN_WORKLOAD_SCRIPT
