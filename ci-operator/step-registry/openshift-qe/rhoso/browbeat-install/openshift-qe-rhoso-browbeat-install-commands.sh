#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)
es_host=$(cat ${CLUSTER_PROFILE_DIR}/elastic_host)
es_port=$(cat ${CLUSTER_PROFILE_DIR}/config | jq ".elastic_port")
build_id="${BUILD_ID:-unknown}"

cat > /tmp/browbeat_install_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh root@${bastion} "
  echo 'Hostname: \$(hostname)'
  rm -rf browbeat
  git clone https://github.com/openstack/browbeat.git
  cd browbeat/ansible
  sed -i \"s|cloud_prefix: .*|cloud_prefix: cpt-${build_id}|\" install/group_vars/all.yml
  sed -i \"s|es_ip: .*|es_ip: ${es_host}|\" install/group_vars/all.yml
  sed -i \"s|es_local_port: .*|es_local_port: ${es_port}|\" install/group_vars/all.yml
  # install browbeat
  ansible-playbook -vvv install/browbeat.yml 2>&1 | tee install.log
  # install and startmetrics collector
  ansible-playbook -vvv install/collectd.yml 2>&1 | tee collectd.log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/browbeat_install_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/browbeat_install_script.sh'
