#!/bin/bash
set -euo pipefail

TOKEN_FILE="${CLUSTER_PROFILE_DIR}/aicli-offlinetoken"
if [[ ! -s "${TOKEN_FILE}" ]]; then
  echo "ERROR: DOCA5 Vault profile is missing a non-empty aicli-offlinetoken" >&2
  exit 1
fi

REMOTE_HOST="$(tr -d '[:space:]' < "${CLUSTER_PROFILE_DIR}/remote-host")"
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "ERROR: remote-host is empty" >&2
  exit 1
fi
if [[ ! "${BUILD_ID:-}" =~ ^[[:alnum:]_.-]+$ ]]; then
  echo "ERROR: BUILD_ID is missing or contains unsupported characters" >&2
  exit 1
fi

SSH_KEY="$(mktemp "${TMPDIR:-/tmp}/doca5-aicli-key.XXXXXX")"
trap 'rm -f "${SSH_KEY}"' EXIT
base64 -d "${CLUSTER_PROFILE_DIR}/private-key" > "${SSH_KEY}"
chmod 600 "${SSH_KEY}"
SSH_OPTS=(-q -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=QUIET -o ConnectTimeout=30 -o BatchMode=yes)

REMOTE_DIR="/root/.aicli"
REMOTE_TOKEN="${REMOTE_DIR}/offlinetoken.txt"
REMOTE_LOCK_DIR="${REMOTE_DIR}/.doca5-aicli-token-lock"
REMOTE_LOCK_OWNER="${REMOTE_LOCK_DIR}/owner"
REMOTE_BACKUP="${REMOTE_TOKEN}.doca5-ci-${BUILD_ID}.backup"
REMOTE_STATE="${REMOTE_TOKEN}.doca5-ci-${BUILD_ID}.state"
REMOTE_STAGED="${REMOTE_TOKEN}.doca5-ci-${BUILD_ID}.staged"

echo "Staging the Vault-backed aicli token for this DOCA5 job"
ssh "${SSH_OPTS[@]}" "root@${REMOTE_HOST}" \
  "set -e; umask 077; mkdir -p '${REMOTE_DIR}'; chmod 700 '${REMOTE_DIR}'; if ! mkdir '${REMOTE_LOCK_DIR}' 2>/dev/null; then echo 'ERROR: another DOCA5 token trial holds the hypervisor lock' >&2; exit 1; fi; printf '%s' '${BUILD_ID}' > '${REMOTE_LOCK_OWNER}'; rm -f '${REMOTE_BACKUP}' '${REMOTE_STATE}' '${REMOTE_STAGED}'; if [ -L '${REMOTE_TOKEN}' ]; then echo 'ERROR: refusing to replace a symlink at ${REMOTE_TOKEN}' >&2; exit 1; elif [ -e '${REMOTE_TOKEN}' ]; then cp -p '${REMOTE_TOKEN}' '${REMOTE_BACKUP}'; chmod 600 '${REMOTE_BACKUP}'; printf present > '${REMOTE_STATE}'; else printf absent > '${REMOTE_STATE}'; fi; chmod 600 '${REMOTE_STATE}'"

# Send the token over SSH stdin; never place its value in a command argument or log.
ssh "${SSH_OPTS[@]}" "root@${REMOTE_HOST}" \
  "umask 077; cat > '${REMOTE_STAGED}' && chmod 600 '${REMOTE_STAGED}' && mv -f '${REMOTE_STAGED}' '${REMOTE_TOKEN}'" \
  < "${TOKEN_FILE}"

echo "DOCA5 aicli token staged; contents were not logged"
