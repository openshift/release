#!/bin/bash

set -euo pipefail

# --- Step 04: Grafana Dashboard Update ---
# Mirrors Jenkins 04-PerfCI-Grafana-Deployment
# SSHes to the provisioner to run the Grafana update pipeline:
# update versions from ES, generate dashboard via grafonnet, upload to Grafana, git push.

# SSH setup — two-hop: Prow → jump host → cluster
if [[ ! -s /secret/jh_priv_ssh_key ]] || [[ ! -s /secret/bastion_address ]]; then
  echo "ERROR: missing SSH credentials (jh_priv_ssh_key / bastion_address)" >&2
  exit 1
fi
cp /secret/jh_priv_ssh_key /tmp/provision_key
chmod 600 /tmp/provision_key

JUMPHOST=$(<"/secret/bastion_address")
JUMPHOST="${JUMPHOST%$'\n'}"
SSH_ARGS="-i /tmp/provision_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=30 -oServerAliveCountMax=5"

# Cluster address for two-hop SSH (scripts run on cluster, not jump host)
CLUSTER_IP=""
[[ -s /secret/cluster_address ]] && CLUSTER_IP=$(<"/secret/cluster_address") && CLUSTER_IP="${CLUSTER_IP%$'\n'}"

# SCP RSA key to jump host for second hop
if [[ -s /secret/provision_private_key ]]; then
  scp ${SSH_ARGS} /secret/provision_private_key root@"${JUMPHOST}":/tmp/provision_private_key
  ssh ${SSH_ARGS} root@"${JUMPHOST}" "chmod 600 /tmp/provision_private_key"
fi

if [[ -n "${CLUSTER_IP}" ]]; then
  REMOTE_SSH="ssh ${SSH_ARGS} root@${JUMPHOST} ssh -i /tmp/provision_private_key -oStrictHostKeyChecking=no root@${CLUSTER_IP}"
else
  REMOTE_SSH="ssh ${SSH_ARGS} root@${JUMPHOST}"
fi

# Read Vault secrets
ELASTICSEARCH=""
[[ -s /secret/elasticsearch ]] && ELASTICSEARCH=$(<"/secret/elasticsearch") && ELASTICSEARCH="${ELASTICSEARCH%$'\n'}"
ES_PORT=""
[[ -s /secret/elasticsearch_port ]] && ES_PORT=$(<"/secret/elasticsearch_port") && ES_PORT="${ES_PORT%$'\n'}"
GRAFANA_URL=""
[[ -s /secret/grafana_url ]] && GRAFANA_URL=$(<"/secret/grafana_url") && GRAFANA_URL="${GRAFANA_URL%$'\n'}"
GRAFANA_API_KEY=""
[[ -s /secret/grafana_api_key ]] && GRAFANA_API_KEY=$(<"/secret/grafana_api_key") && GRAFANA_API_KEY="${GRAFANA_API_KEY%$'\n'}"
GIT_TOKEN=""
[[ -s /secret/git_token ]] && GIT_TOKEN=$(<"/secret/git_token") && GIT_TOKEN="${GIT_TOKEN%$'\n'}"
GIT_REPOSITORY=""
[[ -s /secret/git_repository ]] && GIT_REPOSITORY=$(<"/secret/git_repository") && GIT_REPOSITORY="${GIT_REPOSITORY%$'\n'}"
GIT_EMAIL=""
[[ -s /secret/git_email ]] && GIT_EMAIL=$(<"/secret/git_email") && GIT_EMAIL="${GIT_EMAIL%$'\n'}"
GIT_USERNAME=""
[[ -s /secret/git_username ]] && GIT_USERNAME=$(<"/secret/git_username") && GIT_USERNAME="${GIT_USERNAME%$'\n'}"

# Validate required secrets
MISSING=""
[[ -z "${ELASTICSEARCH}" ]] && MISSING="${MISSING} elasticsearch"
[[ -z "${ES_PORT}" ]] && MISSING="${MISSING} elasticsearch_port"
[[ -z "${GRAFANA_URL}" ]] && MISSING="${MISSING} grafana_url"
[[ -z "${GRAFANA_API_KEY}" ]] && MISSING="${MISSING} grafana_api_key"
[[ -z "${GIT_TOKEN}" ]] && MISSING="${MISSING} git_token"
[[ -z "${GIT_REPOSITORY}" ]] && MISSING="${MISSING} git_repository"
[[ -z "${GIT_EMAIL}" ]] && MISSING="${MISSING} git_email"
[[ -z "${GIT_USERNAME}" ]] && MISSING="${MISSING} git_username"
if [[ -n "${MISSING}" ]]; then
  echo "ERROR: missing required Vault secrets:${MISSING}" >&2
  exit 1
fi

echo "=== Step 04: Grafana Dashboard Update ==="

WORK_DIR="/tmp/grafana-update"

${REMOTE_SSH} \
  "export WORK_DIR='${WORK_DIR}' GIT_BRANCH='${GIT_BRANCH}' ELASTICSEARCH='${ELASTICSEARCH}' ES_PORT='${ES_PORT}' MAIN_LIBSONNET_PATH='${MAIN_LIBSONNET_PATH}' GRAFANA_JSON_PATH='${GRAFANA_JSON_PATH}' GRAFANA_URL='${GRAFANA_URL}' GRAFANA_API_KEY='${GRAFANA_API_KEY}' GRAFANA_FOLDER_NAME='${GRAFANA_FOLDER_NAME}' GIT_TOKEN='${GIT_TOKEN}' GIT_REPOSITORY='${GIT_REPOSITORY}' GIT_EMAIL='${GIT_EMAIL}' GIT_USERNAME='${GIT_USERNAME}'; bash -s" <<'GRAFANA_EOF'
set -euo pipefail

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

git clone --depth 1 -b "${GIT_BRANCH}" https://github.com/redhat-performance/benchmark-runner .
pip3 install --quiet -r requirements.txt 2>/dev/null || true
pip3 install --quiet --upgrade benchmark-runner 2>/dev/null || true

echo "--- Updating versions from Elasticsearch ---"
PYTHONPATH="${WORK_DIR}" python3 benchmark_runner/grafana/update_versions_main_libsonnet.py \
  --elasticsearch="${ELASTICSEARCH}" \
  --elasticsearch_port="${ES_PORT}" \
  --main_libsonnet_path="${MAIN_LIBSONNET_PATH}"

echo "--- Generating dashboard.json via grafonnet ---"
podman run --rm --name run_grafonnet \
  -v "${WORK_DIR}/benchmark_runner/grafana/perf:/app" \
  --privileged quay.io/ebattat/run_grafonnet:latest

CHANGES_LIBSONNET=false
CHANGES_DASHBOARD=false
git diff --quiet "${MAIN_LIBSONNET_PATH}" 2>/dev/null || CHANGES_LIBSONNET=true
git diff --quiet "${GRAFANA_JSON_PATH}" 2>/dev/null || CHANGES_DASHBOARD=true

if [[ "${CHANGES_DASHBOARD}" == "true" ]]; then
  echo "--- Uploading dashboard to Grafana ---"
  cp -p "${GRAFANA_JSON_PATH}" "${GRAFANA_JSON_PATH}.backup"
  PYTHONPATH="${WORK_DIR}" python3 benchmark_runner/grafana/update_grafana_dashboard.py \
    --grafana_url="${GRAFANA_URL}" \
    --grafana_api_key="${GRAFANA_API_KEY}" \
    --grafana_json_path="${GRAFANA_JSON_PATH}" \
    --grafana_folder_name="${GRAFANA_FOLDER_NAME}"
  cp -p "${GRAFANA_JSON_PATH}.backup" "${GRAFANA_JSON_PATH}"
fi

if [[ "${CHANGES_LIBSONNET}" == "true" ]] || [[ "${CHANGES_DASHBOARD}" == "true" ]]; then
  echo "--- Committing and pushing Grafana updates ---"
  git config user.email "${GIT_EMAIL}"
  git config user.name "${GIT_USERNAME}"
  git config pull.rebase false

  [[ "${CHANGES_DASHBOARD}" == "true" ]] && git add "${GRAFANA_JSON_PATH}"
  [[ "${CHANGES_LIBSONNET}" == "true" ]] && git add "${MAIN_LIBSONNET_PATH}"

  git commit -m "Update Grafana files"
  set +x
  git pull "https://${GIT_TOKEN}@${GIT_REPOSITORY}" "${GIT_BRANCH}" > /tmp/git-pull.log 2>&1 || { echo "ERROR: git pull failed"; cat /tmp/git-pull.log | grep -v "${GIT_TOKEN}"; exit 1; }
  git push "https://${GIT_TOKEN}@${GIT_REPOSITORY}" "${GIT_BRANCH}" > /tmp/git-push.log 2>&1 || { echo "ERROR: git push failed"; cat /tmp/git-push.log | grep -v "${GIT_TOKEN}"; exit 1; }
  set -x
  echo "--- Changes pushed ---"
else
  echo "--- No changes to commit ---"
fi

podman rmi -f quay.io/ebattat/run_grafonnet:latest 2>/dev/null || true
rm -rf "${WORK_DIR}"
GRAFANA_EOF

echo "=== Step 04 complete ==="
