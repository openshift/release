#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

cat > /tmp/nfv-e2e-cleanup.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=240 zuul@${bastion} "
  cd /home/zuul/netperf-rhoso18-nfv-e2e-validation
  make e2e-clean SCENARIO=${SCENARIO} LAB_ENV=~/nfv-e2e/lab-init.env
"
EOF

scp -q ${SSH_ARGS} /tmp/nfv-e2e-cleanup.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/nfv-e2e-cleanup.sh'
