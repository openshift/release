#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion 2>/dev/null || cat ${SHARED_DIR}/bastion)

# e.g. "0b-keepalive,0b-nokeepalive,1k" → {"payload_sizes":["0b-keepalive","0b-nokeepalive","1k"]}
payload_json=$(echo "${PAYLOAD_SIZES}" | sed 's/,/","/g; s/^/{"payload_sizes":["/; s/$/"]}/') 
echo "${payload_json}" > /tmp/payload_vars.json

cat > /tmp/dataplane_run_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

scp -o StrictHostKeyChecking=no /tmp/payload_vars.json root@${bastion}:/tmp/payload_vars.json

ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=240 root@${bastion} "
  set -o errexit
  set -o pipefail
  cd rhoso-octavia-dataplane-performance
  ansible-playbook -vvv -i inventory run-workloads.yaml \
    --tags ${DATAPLANE_TAGS} \
    -e collect_metrics=true \
    -e @/tmp/payload_vars.json \
    2>&1 | tee run-workloads.log
"
EOF

# Transfer extra-vars file and run script to jumphost, then execute
scp -q ${SSH_ARGS} /tmp/payload_vars.json root@${jumphost}:/tmp/
scp -q ${SSH_ARGS} /tmp/dataplane_run_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/dataplane_run_script.sh'
