#!/bin/bash
set -x

SSH_ARGS="-i /bm/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion="$(cat /bm/address)"
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD

echo "LAB is $LAB_CLOUD"

SCRIPT_FILE="remote_script.sh"

cat > $SCRIPT_FILE << 'EOF'
#!/bin/bash
set -x
LAB_CLOUD=$1
export KUBECONFIG=/root/vmno/kubeconfig
LOGIN=password
INVENTORY_FILE="/root/jetlag/ansible/inventory/$LAB_CLOUD.local"
CREATE_VM_SCRIPT="create_vm_script.sh"
RUN_WORKLOAD_SCRIPT="run_workload.sh"
source /root/jetlag/.ansible/bin/activate

# Get the list of hosts in the 'hv_vm' group
HOSTS=$(ansible-inventory -i "$INVENTORY_FILE" --list | jq -r '.hv_vm.hosts[]')

# Get the last host from the list
VM_NAME=$(echo "$HOSTS" | tail -n 1)

# Get the value of hv_ip for the last host
HV_IP=$(ansible-inventory -i "$INVENTORY_FILE" --host "$VM_NAME" | jq -r '.hv_ip')
VM_IP=$(ansible-inventory -i "$INVENTORY_FILE" --host "$VM_NAME" | jq -r '.ip')

# Print the extracted value 
echo "The ip for the last entry is: $VM_NAME $HV_IP $VM_IP"
deactivate

#TODO
SSH_ARGS='-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null'

#!/bin/bash

# Define the name of the script to be created
SOURCE_IMAGE="/var/lib/libvirt/images/rhel-guest-image.qcow2"
DEST_IMAGE="/mnt/disk2/libvirt/images/$VM_NAME.qcow2"

cat > $CREATE_VM_SCRIPT << _EOF_
#!/bin/bash

set -x

curl -o "$SOURCE_IMAGE" http://download.eng.bos.redhat.com/released/rhel-6-7-8/rhel-8/RHEL-8/8.10.0/BaseOS/x86_64/images/rhel-guest-image-8.10-1362.x86_64.qcow2
qemu-img create -f qcow2 "$DEST_IMAGE" 120G

virt-resize --expand "/dev/sda3" "$SOURCE_IMAGE" "$DEST_IMAGE"

virt-customize -a "$DEST_IMAGE" --root-password password:"$LOGIN"
virt-customize -a "$DEST_IMAGE" \
 --run-command 'cat << __EOF__ > /etc/sysconfig/network-scripts/ifcfg-eth0
TYPE=Ethernet
BOOTPROTO=none
DEFROUTE=yes
IPADDR='$VM_IP'
PREFIX=24
GATEWAY=198.18.0.1
DNS1=8.8.8.8
ONBOOT=yes
NAME=eth0
__EOF__'

virsh start "$VM_NAME"
sleep 90
_EOF_

echo "Script '$CREATE_VM_SCRIPT' created. Now you can use it with SSH."

chmod +x $CREATE_VM_SCRIPT
ssh -i /root/.ssh/id_rsa ${SSH_ARGS} root@${HV_IP} 'bash -s' < $CREATE_VM_SCRIPT

ssh-keygen -R $VM_IP 2>/dev/null || true
ssh-keyscan $VM_IP >> ~/.ssh/known_hosts

# Copy hosts file and kubeconfig from bastion host
sshpass -p "$LOGIN" scp /root/vmno/kubeconfig root@$VM_IP:~/
sshpass -p "$LOGIN" scp /etc/hosts /etc/resolv.conf root@$VM_IP:/etc/

cat > $RUN_WORKLOAD_SCRIPT << _EOF_
#!/bin/bash

set -x
cat << __EOF__ > /etc/yum.repos.d/RHEL810-AppStream.repo
[rhel810-appstream]
name=RHEL810 AppStream
baseurl=http://mirror.scalelab.redhat.com/RHEL8/8.10.0/AppStream/x86_64/os/
enabled=1
gpgcheck=0
__EOF__

# Create the RHEL810-BaseOS.repo file
cat << __EOF__ > /etc/yum.repos.d/RHEL810-BaseOS.repo
[rhel810-baseos]
name=RHEL810 BaseOS
baseurl=http://mirror.scalelab.redhat.com/RHEL8/8.10.0/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
__EOF__

dnf install curl git make binutils bison gcc glibc-devel golang podman jq -y
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz | tar -xvzf -
mv oc kubectl /usr/bin/
export KUBECONFIG=/root/kubeconfig

bash < <(curl -sSL https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer)
source ~/.gvm/scripts/gvm
echo 'source ~/.gvm/scripts/gvm' >> ~/.bashrc
gvm install go1.23
gvm use go1.23 --default

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

git clone https://github.com/kube-burner/kube-burner-ocp
cd kube-burner-ocp
make clean; make build
bin/amd64/kube-burner-ocp udn-bgp --iterations 1 --check-health=false --profile-type=regular --log-level=debug --local-indexing

_EOF_
chmod +x $RUN_WORKLOAD_SCRIPT
sshpass -p "$LOGIN" ssh ${SSH_ARGS} root@${VM_IP} 'bash -s' < $RUN_WORKLOAD_SCRIPT
EOF

ssh ${SSH_ARGS} root@$bastion 'bash -s --' "$LAB_CLOUD" < $SCRIPT_FILE
