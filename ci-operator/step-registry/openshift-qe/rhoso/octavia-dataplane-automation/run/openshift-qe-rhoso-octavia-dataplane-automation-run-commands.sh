#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion 2>/dev/null || cat ${SHARED_DIR}/bastion)

# Convert comma-separated PAYLOAD_SIZES to JSON list for ansible -e
# e.g. "0b-keepalive,0b-nokeepalive,1k" → '["0b-keepalive","0b-nokeepalive","1k"]'
payload_json=$(echo "${PAYLOAD_SIZES}" | sed 's/,/","/g; s/^/["/; s/$/"]/')

cat > /tmp/dataplane_run_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=240 root@${bastion} "
  set -o errexit
  set -o pipefail
  cd rhoso-octavia-dataplane-performance
  ansible-playbook -vvv -i inventory run-workloads.yaml \
    --tags ${DATAPLANE_TAGS} \
    -e collect_metrics=true \
    -e '{\"payload_sizes\":${payload_json}}' \
    2>&1 | tee run-workloads.log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/dataplane_run_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/dataplane_run_script.sh'
