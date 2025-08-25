#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat ${CLUSTER_PROFILE_DIR}/address)
bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)
build_id="${BUILD_ID:-unknown}"
nfs_host=$(cat ${CLUSTER_PROFILE_DIR}/nfs_host)
nfs_path=$(cat ${CLUSTER_PROFILE_DIR}/nfs_path)

cat > /tmp/browbeat_results_backup_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh root@${bastion} "
  if mount | grep -qE \"^${nfs_host}:${nfs_path} on /mnt/ \"; then
    echo \"NFS already mounted\"
  else
    mount -t nfs \"${nfs_host}:${nfs_path}\" /mnt/
  fi
  cd browbeat/results
  mkdir -p /mnt/${build_id}
  cp -rf * /mnt/${build_id}
  umount /mnt
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/browbeat_results_backup_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/browbeat_results_backup_script.sh'
