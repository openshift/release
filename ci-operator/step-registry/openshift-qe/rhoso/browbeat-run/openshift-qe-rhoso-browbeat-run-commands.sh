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
kubeconfig=$(cat ${CLUSTER_PROFILE_DIR}/kubeconfig)
config_file="cpt-${WORKLOAD}.yaml"

cat > /tmp/browbeat_run_script.sh <<EOF
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ssh root@${bastion} "
  # Export CI metadata and ES host to the remote environment
  export PROW_JOB_ID=\"${PROW_JOB_ID:-}\"
  export JOB_TYPE=\"${JOB_TYPE:-}\"
  export JOB_NAME=\"${JOB_NAME:-}\"
  export BUILD_ID=\"${BUILD_ID:-}\"
  export REPO_OWNER=\"${REPO_OWNER:-}\"
  export REPO_NAME=\"${REPO_NAME:-}\"
  export PULL_NUMBER=\"${PULL_NUMBER:-}\"
  export ES_SERVER=\"${es_host}\"
  export KUBECONFIG=\"${kubeconfig}\"
  JOB_START=\\\$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")
  rm -rf cpt-browbeat-config
  git clone https://gitlab.cee.redhat.com/eng/openstack/team/performance-and-scale/cpt-browbeat-configs.git
  cd cpt-browbeat-configs
  if [ ! -f ${config_file} ]; then
    echo 'Config ${config_file} not found. Set WORKLOAD env var (e.g., WORKLOAD=nova).' >&2
    exit 1
  fi
  echo Using ${config_file}
  cp -f ${config_file} ../browbeat/browbeat-config.yaml
  cd ../browbeat
  sed -i \"s|cloud_name: .*|cloud_name: cpt-${build_id}|\" browbeat-config.yaml
  sed -i \"s|host: .*|host: ${es_host}|\" browbeat-config.yaml
  source .browbeat-venv/bin/activate
  log_file=\"browbeat-rally-${WORKLOAD}-${build_id}.log\"
  export BROWBEAT_LOG=\"\\\$(pwd)/\\\${log_file}\"
  set -o pipefail
  python3 browbeat.py rally 2>&1 | tee \"\\\$log_file\"
  deactivate
  JOB_END=\\\$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")
  export JOB_START JOB_END BROWBEAT_LOG
  if [ -f utils/index-cpt-jobs.sh ]; then
    chmod +x utils/index-cpt-jobs.sh || true
    bash utils/index-cpt-jobs.sh
  fi
"
EOF

# Transfer and execute the script on jumphost
scp -q ${SSH_ARGS} /tmp/browbeat_run_script.sh root@${jumphost}:/tmp/
ssh ${SSH_ARGS} root@${jumphost} 'bash /tmp/browbeat_run_script.sh'
