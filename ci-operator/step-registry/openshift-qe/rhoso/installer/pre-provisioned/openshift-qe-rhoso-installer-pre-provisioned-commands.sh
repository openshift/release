#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

lab=$(cat ${CLUSTER_PROFILE_DIR}/lab)
lab_cloud=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
compute_count=$(cat ${CLUSTER_PROFILE_DIR}/config | jq ".compute_count")
ctlplane_start_ip=$(cat ${CLUSTER_PROFILE_DIR}/ctlplane_start_ip)
kubeconfig=$(cat ${CLUSTER_PROFILE_DIR}/kubeconfig)
username=$(cat ${CLUSTER_PROFILE_DIR}/username)
password=$(cat ${CLUSTER_PROFILE_DIR}/login)
ssh_key_file=$(cat ${CLUSTER_PROFILE_DIR}/ssh_key_path)
nova_migration_key=$(cat ${CLUSTER_PROFILE_DIR}/nova_migration_key)
amphora_container_image=$(cat ${CLUSTER_PROFILE_DIR}/amphora_container_image)

ceph_backend=$(cat ${CLUSTER_PROFILE_DIR}/ceph_backend)
ceph_admin_node=$(cat ${CLUSTER_PROFILE_DIR}/ceph_admin_node)

cat <<EOF >>/tmp/all.yml
---
lab: $lab
cloud: $lab_cloud
compute_count: $compute_count
dt_path: /tmp/RHOSO
ssh_username: $username
ssh_password: $password
ssh_key_file: $ssh_key_file
nova_migration_key: $nova_migration_key
ctlplane_start_ip: $ctlplane_start_ip
ceph_backend: $ceph_backend
ceph_admin_node: $ceph_admin_node
ceph_admin_user: root
ceph_admin_password: $password
ceph_config_local_path: /root/ceph-config
amphora_image_container_image: $amphora_container_image
ocp_environment:
  KUBECONFIG: $kubeconfig
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

cat /tmp/all-updated.yml

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${jumphost}:/tmp/rhoso_all.yml


cat > /tmp/deployment_script.sh <<EOF
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
  ansible-playbook -vvv main.yml 2>&1 | tee log
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/deployment_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/deployment_script.sh'
