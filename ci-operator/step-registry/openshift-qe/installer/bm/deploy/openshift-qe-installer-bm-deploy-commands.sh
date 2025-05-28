#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
CRUCIBLE_URL=$(cat ${CLUSTER_PROFILE_DIR}/crucible_url)
JETLAG_PR=${JETLAG_PR:-}
REPO_NAME=${REPO_NAME:-}
PULL_NUMBER=${PULL_NUMBER:-}
KUBECONFIG_SRC=""
BASTION_CP_INTERFACE=$(cat ${CLUSTER_PROFILE_DIR}/bastion_cp_interface)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
export LAB_CLOUD
LAB_INTERFACE=$(cat ${CLUSTER_PROFILE_DIR}/lab_interface)

cat <<EOF >>/tmp/all.yml
---
lab: $LAB
lab_cloud: $LAB_CLOUD
cluster_type: $TYPE
worker_node_count: $NUM_WORKER_NODES
ocp_version: $OCP_VERSION
ocp_build: $OCP_BUILD
public_vlan: $PUBLIC_VLAN
sno_use_lab_dhcp: false
enable_fips: $FIPS
ssh_private_key_file: ~/.ssh/id_rsa
ssh_public_key_file: ~/.ssh/id_rsa.pub
pull_secret: "{{ lookup('file', '../pull_secret.txt') }}"
bastion_cluster_config_dir: /root/{{ cluster_type }}
bastion_controlplane_interface: $BASTION_CP_INTERFACE
bastion_lab_interface: $LAB_INTERFACE
controlplane_lab_interface: $LAB_INTERFACE
setup_bastion_gogs: false
setup_bastion_registry: false
use_bastion_registry: false
install_rh_crucible: $CRUCIBLE
rh_crucible_url: "$CRUCIBLE_URL"
EOF

if [[ $PUBLIC_VLAN == "false" ]]; then
  echo -e "controlplane_network: 192.168.216.1/21\ncontrolplane_network_prefix: 21" >> /tmp/all.yml
fi

envsubst < /tmp/all.yml > /tmp/all-updated.yml

# Clean up previous attempts
cat > /tmp/clean-resources.sh << 'EOF'
echo 'Running clean-resources.sh'
dnf install -y podman
podman pod stop $(podman pod ps -q) || echo 'No podman pods to stop'
podman pod rm $(podman pod ps -q)   || echo 'No podman pods to delete'
podman stop $(podman ps -aq)        || echo 'No podman containers to stop'
podman rm $(podman ps -aq)          || echo 'No podman containers to delete'
rm -rf /opt/*
EOF

# Pre-reqs
cat > /tmp/prereqs.sh << 'EOF'
echo "Running prereqs.sh"
podman pull quay.io/quads/badfish:latest
USER=$(curl -sSk $QUADS_INSTANCE | jq -r ".nodes[0].pm_user")
PWD=$(curl -sSk $QUADS_INSTANCE  | jq -r ".nodes[0].pm_password")
if [[ "$TYPE" == "mno" ]]; then
  HOSTS=$(curl -sSk $QUADS_INSTANCE | jq -r ".nodes[1:4+"$NUM_WORKER_NODES"][].name")
elif [[ "$TYPE" == "sno" ]]; then
  HOSTS=$(curl -sSk $QUADS_INSTANCE | jq -r ".nodes[1:2][].name")
fi
echo "Hosts to be prepared: $HOSTS"
# IDRAC reset
if [[ "$PRE_RESET_IDRAC" == "true" ]]; then
  echo "Resetting IDRACs ..."
  for i in $HOSTS; do
    echo "Resetting IDRAC of server $i ..."
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PWD --racreset
  done
  for i in $HOSTS; do
    if ! podman run quay.io/quads/badfish -H mgmt-$i -u $USER -p $PWD --power-state; then
      echo "$i iDRAC is still rebooting"
      continue
    fi
  done
fi
if [[ "$PRE_PXE_LOADER" == "true" ]]; then
  echo "Modifying PXE loaders ..."
  for i in $HOSTS; do
    echo "Modifying PXE loader of server $i ..."
    hammer --verify-ssl false -u $LAB_CLOUD -p $PWD host update --name $i --operatingsystem "$FOREMAN_OS" --pxe-loader "PXELinux BIOS" --build 1
  done
fi
if [[ "$PRE_CLEAR_JOB_QUEUE" == "true" ]]; then
  echo "Clearing job queue ..."
  for i in $HOSTS; do
    echo "Clear job queue of server $i ..."
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PWD --clear-jobs --force
  done
fi
if [[ "$PRE_BOOT_ORDER" == "true" ]]; then
  echo "Cheking boot order ..."
  for i in $HOSTS; do
    # Until https://github.com/redhat-performance/badfish/issues/411 gets sorted
    command_output=$(podman run quay.io/quads/badfish:latest -H mgmt-$i -u $USER -p $PWD -i config/idrac_interfaces.yml -t foreman 2>&1)
    desired_output="- WARNING  - No changes were made since the boot order already matches the requested."
    echo "Cheking boot order of server $i ..."
    echo $command_output
    if [[ "$command_output" != "$desired_output" ]]; then
      WAIT=true
      echo "Boot order changed in server $i"
    fi
  done
fi
if [ $WAIT ]; then
  echo "Waiting after boot order changes ..."
  sleep 300
fi
if [[ "$PRE_UEFI" == "true" ]]; then
  echo "Cheking UEFI setup ..."
  for i in $HOSTS; do
    echo "Cheking UEFI setup of server $i ..."
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PWD --set-bios-attribute --attribute BootMode --value Uefi
    if [[ $(podman run quay.io/quads/badfish -H mgmt-$i -u $USER -p $PWD --get-bios-attribute --attribute BootMode --value Uefi -o json 2>&1 | jq -r .CurrentValue) != "Uefi" ]]; then
      echo "$i not in Uefi mode"
      sleep 10s
      continue
    fi
  done
fi
EOF
if [[ $LAB == "performancelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu3.labs.perfscale.redhat.com/instack/$LAB_CLOUD\_ocpinventory.json"
elif [[ $LAB == "scalelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu2.scalelab.redhat.com/instack/$LAB_CLOUD\_ocpinventory.json"
fi
envsubst '${FOREMAN_OS},${LAB_CLOUD},${NUM_WORKER_NODES},${PRE_CLEAR_JOB_QUEUE},${PRE_PXE_LOADER},${PRE_RESET_IDRAC},${PRE_UEFI},${QUADS_INSTANCE},${TYPE}' < /tmp/prereqs.sh > /tmp/prereqs-updated.sh

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

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${bastion}:${jetlag_repo}/ansible/vars/all.yml
scp -q ${SSH_ARGS} ${CLUSTER_PROFILE_DIR}/pull_secret root@${bastion}:${jetlag_repo}/pull_secret.txt
scp -q ${SSH_ARGS} /tmp/clean-resources.sh root@${bastion}:/tmp/
scp -q ${SSH_ARGS} /tmp/prereqs-updated.sh root@${bastion}:/tmp/

if [[ ${TYPE} == 'sno' ]]; then
  KUBECONFIG_SRC='/root/sno/{{ groups.sno[0] }}/kubeconfig'
else
  KUBECONFIG_SRC=/root/${TYPE}/kubeconfig
fi

ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${jetlag_repo}
   source .ansible/bin/activate
   ansible-playbook ansible/create-inventory.yml | tee /tmp/ansible-create-inventory-$(date +%s)
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m script -a /tmp/clean-resources.sh
   source /tmp/prereqs-updated.sh
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/setup-bastion.yml | tee /tmp/ansible-setup-bastion-$(date +%s)
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/${TYPE}-deploy.yml -v | tee /tmp/ansible-${TYPE}-deploy-$(date +%s)
   mkdir -p /root/$LAB/$LAB_CLOUD/$TYPE
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m fetch -a 'src=${KUBECONFIG_SRC} dest=/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig flat=true'
   deactivate
   rm -rf .ansible
"

scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig ${SHARED_DIR}/kubeconfig
