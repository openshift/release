#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)
build_id="${BUILD_ID:-unknown}"
es_host=$(cat ${CLUSTER_PROFILE_DIR}/elastic_host)

cat > /tmp/browbeat_nova_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh root@${bastion} "
  cd browbeat
  cp -f conf/cpt-nova.yaml browbeat-config.yaml
  sed -i \"s|cloud_name: .*|cloud_name: cpt-${build_id}|\" browbeat-config.yaml
  sed -i \"s|host: .*|host: ${es_host}|\" browbeat-config.yaml
  source .browbeat-venv/bin/activate
  python3 browbeat.py rally
  deactivate
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/browbeat_nova_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/browbeat_nova_script.sh'
