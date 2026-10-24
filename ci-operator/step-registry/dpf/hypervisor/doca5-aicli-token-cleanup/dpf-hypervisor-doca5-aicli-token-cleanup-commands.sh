#!/bin/bash
set -euo pipefail

if [[ ! "${BUILD_ID:-}" =~ ^[[:alnum:]_.-]+$ ]]; then
  echo "ERROR: BUILD_ID is missing or contains unsupported characters" >&2
  exit 1
fi

REMOTE_HOST="$(tr -d '[:space:]' < "${CLUSTER_PROFILE_DIR}/remote-host")"
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "ERROR: remote-host is empty" >&2
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

echo "Cleaning up the DOCA5 job's staged aicli token"
if ! ssh "${SSH_OPTS[@]}" "root@${REMOTE_HOST}" \
  "set -e; if [ ! -f '${REMOTE_LOCK_OWNER}' ] || [ \"\$(cat '${REMOTE_LOCK_OWNER}')\" != '${BUILD_ID}' ]; then echo 'No DOCA5 token lock owned by this job; nothing to clean'; exit 0; fi; if [ -f '${REMOTE_STATE}' ]; then state=\$(cat '${REMOTE_STATE}'); case \"\${state}\" in present) if [ -f '${REMOTE_BACKUP}' ]; then mv -f '${REMOTE_BACKUP}' '${REMOTE_TOKEN}'; chmod 600 '${REMOTE_TOKEN}'; else echo 'ERROR: previous token backup is missing; leaving current token untouched' >&2; exit 1; fi ;; absent) rm -f '${REMOTE_TOKEN}' ;; *) echo 'ERROR: invalid DOCA5 token staging state' >&2; exit 1 ;; esac; else echo 'No token staging state was written; leaving the original token untouched'; fi; rm -f '${REMOTE_BACKUP}' '${REMOTE_STATE}' '${REMOTE_STAGED}' '${REMOTE_LOCK_OWNER}'; rmdir '${REMOTE_LOCK_DIR}'"; then
  echo "WARNING: failed to clean up the DOCA5 aicli token on ${REMOTE_HOST}; manual cleanup may be needed" >&2
  exit 0
fi

echo "DOCA5 aicli token cleanup complete"
