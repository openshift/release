#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)


cat > /tmp/browbeat_install_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
jumphost="${jumphost}"
bastion="${bastion}"

ssh root@${bastion} "
  echo 'Hostname: \$(hostname)'
  rm -rf browbeat
  git clone https://github.com/openstack/browbeat.git
  cd browbeat/ansible
  ansible-playbook -vvv install/browbeat.yml 2>&1 | tee log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/browbeat_install_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/browbeat_install_script.sh'
