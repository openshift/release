#!/bin/bash
set -euo pipefail
set +x
trap 'rm -f "${SHARED_DIR}/microshift-perf-es-credentials.json" "${SHARED_DIR}/microshift-perf-es-url"' EXIT
# Best-effort secret cleanup precedes the unconditional reservation terminate ref.
if [[ -f "${SHARED_DIR}/microshift-perf-cycle-id" && -f "$CLUSTER_PROFILE_DIR/address" ]]; then
  cycle=$(cat "${SHARED_DIR}/microshift-perf-cycle-id")
  [[ $cycle =~ ^[a-f0-9-]{36}$ ]] || exit 1
  bastion=$(cat "$CLUSTER_PROFILE_DIR/address")
  if [[ -f "${SHARED_DIR}/microshift-perf-deploy.json" ]]; then
    repo=$(jq -r .automation_repo "${SHARED_DIR}/microshift-perf-deploy.json")
    [[ $repo =~ ^/tmp/microshift-[a-zA-Z0-9_-]+$ ]] || exit 1
    # shellcheck disable=SC2029 # Validated job-owned paths expanded intentionally.
    timeout -k 5 20 ssh -i "$CLUSTER_PROFILE_DIR/jh_priv_ssh_key" -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oConnectTimeout=5 "root@$bastion" \
      "rm -f '$repo/ansible/.perf-es-credentials.json' '$repo/ansible/.perf-install-vars.json'; find '/tmp/microshift-perf-$cycle' -maxdepth 2 -name credentials.json -delete" 2>/dev/null || true
  fi
fi
rm -f "${SHARED_DIR}/microshift-perf-es-credentials.json" "${SHARED_DIR}/microshift-perf-es-url"
