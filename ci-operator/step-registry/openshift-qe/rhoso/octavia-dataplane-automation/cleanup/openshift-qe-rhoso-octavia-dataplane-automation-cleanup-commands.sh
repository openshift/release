#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion 2>/dev/null || cat ${SHARED_DIR}/bastion)

cat > /tmp/dataplane_cleanup_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh root@${bastion} "
  set -o errexit
  set -o pipefail
  cd rhoso-octavia-dataplane-performance
  ansible-playbook -vvv cleanup-infrastructure.yaml 2>&1 | tee cleanup-infrastructure.log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/dataplane_cleanup_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/dataplane_cleanup_script.sh'
