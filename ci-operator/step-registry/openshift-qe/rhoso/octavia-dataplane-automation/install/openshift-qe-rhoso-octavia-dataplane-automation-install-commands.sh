#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion 2>/dev/null || cat ${SHARED_DIR}/bastion)

cat > /tmp/dataplane_install_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh root@${bastion} "
  set -o errexit
  set -o pipefail
  echo 'Hostname: \$(hostname)'
  rm -rf rhoso-octavia-dataplane-performance
  git clone https://github.com/redhat-performance/rhoso-octavia-dataplane-performance.git
  cd rhoso-octavia-dataplane-performance
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook -vvv setup-infrastructure.yaml \
    -e client_vm_vcpus=${CLIENT_VM_VCPUS} \
    -e member_vm_vcpus=${MEMBER_VM_VCPUS} \
    2>&1 | tee setup-infrastructure.log
  ansible-playbook -vvv generate-inventory.yaml 2>&1 | tee generate-inventory.log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/dataplane_install_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/dataplane_install_script.sh'
