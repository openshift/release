#!/bin/bash

set -euo pipefail

# --- Step 05: Backup & Report ---
# Mirrors Jenkins 05-PerfCI-Backup-Report-Deployment
# SSHes through jump host to cluster to run:
# 1. CI pod deployment (ES, Kibana, Grafana, JupyterLab for summary reports)
# 2. Google Drive backup of artifacts

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

# Read script paths from Vault
DEPLOYMENT_POD_SCRIPT=""
[[ -s /secret/deployment_pod_script ]] && DEPLOYMENT_POD_SCRIPT=$(<"/secret/deployment_pod_script") && DEPLOYMENT_POD_SCRIPT="${DEPLOYMENT_POD_SCRIPT%$'\n'}"
BACKUP_SCRIPT=""
[[ -s /secret/backup_script ]] && BACKUP_SCRIPT=$(<"/secret/backup_script") && BACKUP_SCRIPT="${BACKUP_SCRIPT%$'\n'}"

if [[ -z "${DEPLOYMENT_POD_SCRIPT}" ]] || [[ -z "${BACKUP_SCRIPT}" ]]; then
  echo "ERROR: missing required Vault secrets: deployment_pod_script / backup_script" >&2
  exit 1
fi

echo "=== Step 05: Backup & Report ==="

# --- Deploy CI Pod & Generate Report ---
echo "--- Running CI pod deployment and report generation ---"
${REMOTE_SSH} "set -euo pipefail; if [[ -x '${DEPLOYMENT_POD_SCRIPT}' ]]; then '${DEPLOYMENT_POD_SCRIPT}'; else echo 'WARNING: deployment pod script not found' >&2; fi"

# --- Backup to Google Drive ---
echo "--- Running Google Drive backup ---"
${REMOTE_SSH} "set -euo pipefail; if [[ -x '${BACKUP_SCRIPT}' ]]; then '${BACKUP_SCRIPT}'; else echo 'WARNING: backup script not found' >&2; fi"

echo "=== Step 05 complete ==="
