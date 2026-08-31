#!/bin/bash

set -euo pipefail

# --- Step 05: Backup & Report ---
# Mirrors Jenkins 05-PerfCI-Backup-Report-Deployment
# SSHes to cluster to run:
# 1. CI pod deployment (ES, Kibana, Grafana, JupyterLab for summary reports)
# 2. Google Drive backup of artifacts

# SSH setup: direct (cluster_address) primary, bastion fallback
if [[ -s /secret/cluster_address ]] && [[ -s /secret/provision_private_key ]]; then
  CLUSTER_IP=$(<"/secret/cluster_address")
  CLUSTER_IP="${CLUSTER_IP%$'\n'}"
  cp /secret/provision_private_key /tmp/cluster_key
  chmod 600 /tmp/cluster_key
  SSH_ARGS="-i /tmp/cluster_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=30 -oServerAliveCountMax=5"
elif [[ -s /secret/bastion_address ]] && [[ -s /secret/jh_priv_ssh_key ]]; then
  CLUSTER_IP=$(<"/secret/bastion_address")
  CLUSTER_IP="${CLUSTER_IP%$'\n'}"
  cp /secret/jh_priv_ssh_key /tmp/cluster_key
  chmod 600 /tmp/cluster_key
  SSH_ARGS="-i /tmp/cluster_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=30 -oServerAliveCountMax=5"
else
  echo "ERROR: need cluster_address+provision_private_key or bastion_address+jh_priv_ssh_key" >&2
  exit 1
fi

REMOTE_SSH="ssh ${SSH_ARGS} root@${CLUSTER_IP}"

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
