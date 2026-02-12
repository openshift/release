#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

kubeconfig=$(cat ${CLUSTER_PROFILE_DIR}/kubeconfig)

cat <<EOF >>/tmp/all.yml
---
ocp_environment:
  KUBECONFIG: $kubeconfig
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

cat /tmp/all-updated.yml

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${jumphost}:/tmp/rhoso_all.yml


cat > /tmp/uninstaller_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
jumphost="${jumphost}"
bastion="${bastion}"

ssh root@${bastion} "
  echo 'Hostname: \$(hostname)'
  rm -rf JetBrew
  git clone https://github.com/redhat-performance/JetBrew.git
  cd JetBrew/ansible
  scp root@${jumphost}:/tmp/rhoso_all.yml group_vars/all.yml
  ansible-playbook -vvv delete-rhoso.yml 2>&1 | tee log-delete-rhoso.log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/uninstaller_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/uninstaller_script.sh'
