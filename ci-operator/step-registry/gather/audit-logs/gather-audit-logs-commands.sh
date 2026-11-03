#!/bin/bash

function summarize_audit_failures() {
  local start end member inputs=0
  local destination="${ARTIFACT_DIR}/audit-server-failures"
  mkdir -p "${destination}"
  start=$(cat "${SHARED_DIR}/conformance-start" 2>/dev/null) || return 0
  end=$(cat "${SHARED_DIR}/conformance-end" 2>/dev/null) || end=$(date -u +%s)
  if [[ ! ${start} =~ ^[0-9]{1,10}$ || ! ${end} =~ ^[0-9]{1,10}$ ]] || (( start > end )); then
    echo 'Invalid conformance window; cannot select server audit failures.' > "${destination}/gap.txt"
    return 0
  fi
  start=$(date -u -d "@$((start > 300 ? start - 300 : 0))" +%FT%T)
  end=$(date -u -d "@$((end + 300))" +%FT%T)
  : > "${destination}/entries.jsonl"
  while IFS= read -r -d '' member; do
    inputs=$((inputs + 1))
    if ! (
      set -o pipefail
      if [[ ${member} == *.gz ]]; then gzip -cd -- "${member}"; else cat -- "${member}"; fi |
        jq -Rc --arg start "${start}" --arg end "${end}" \
          --arg member "${member#"${ARTIFACT_DIR}/audit-logs/"}" '
          fromjson | select(.stage == "ResponseComplete" and (.responseStatus.code // 0) >= 500) |
          select(.requestReceivedTimestamp >= $start and .requestReceivedTimestamp < $end) |
          {auditID, verb, stage, requestReceivedTimestamp, stageTimestamp,
           serverCode: .responseStatus.code,
           object: ((.objectRef // {}) | if .resource == "pods" then
             {resource, namespace, name, subresource} else {resource, subresource} end),
           etcdLatency: .annotations["apiserver.latency.k8s.io/etcd"],
           totalLatency: .annotations["apiserver.latency.k8s.io/total"],
           auditMember: $member,
           correlation: "server observation only; match client Audit-ID, or explicitly correlate object, verb and request time; not a client HTTP response"}'
    ) >> "${destination}/entries.jsonl" 2>/dev/null; then
      echo 'Audit input could not be fully decoded; summary may be incomplete. Inspect the retained audit archive and gather logs.' >> "${destination}/gap.txt"
    fi
  done < <(find "${ARTIFACT_DIR}/audit-logs" -type f \( -name '*audit*.log' -o -name '*audit*.log.gz' \) -print0)
  if (( inputs == 0 )); then
    echo 'No audit log members found; check must-gather completion and audit retention.' >> "${destination}/gap.txt"
  fi
  jq -n --arg start "${start}" --arg end "${end}" \
    '{start: $start, endExclusive: $end,
      interpretation: "Server 5xx candidates, not proof that a failing client received an HTTP response. Match Audit-ID where retained; otherwise label object/verb/time correlation explicitly. Original test errors are unchanged. Empty output does not prove absence of failures; verify audit coverage."}' \
    > "${destination}/README.json"
}

if [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  return
fi

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering audit logs."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Allow a job to override the must-gather image, this is needed for
# disconnected environments prior to 4.8.
if test -f "${SHARED_DIR}/must-gather-image.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/must-gather-image.sh"
else
	MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-""}
fi

mkdir -p "${ARTIFACT_DIR}/audit-logs"
VOLUME_PERCENTAGE_FLAG=""
if oc adm must-gather --help 2>&1 | grep -q -- '--volume-percentage'; then
   VOLUME_PERCENTAGE_FLAG="--volume-percentage=100"
fi

audit_gather_status=0
oc adm must-gather $MUST_GATHER_IMAGE $VOLUME_PERCENTAGE_FLAG --dest-dir="${ARTIFACT_DIR}/audit-logs" -- /usr/bin/gather_audit_logs || audit_gather_status=$?
if ! tar -czC "${ARTIFACT_DIR}/audit-logs" -f "${ARTIFACT_DIR}/audit-logs.tar.gz" .; then
  echo 'Audit archive creation failed; leaving gathered logs in audit-logs for artifact retention.' >&2
  exit 1
fi
if [[ -f ${SHARED_DIR}/conformance-start ]]; then
  summarize_audit_failures
  if (( audit_gather_status != 0 )); then
    echo 'Audit must-gather failed; summary/archive may be incomplete. Check gather logs and retained member coverage.' >> "${ARTIFACT_DIR}/audit-server-failures/gap.txt"
  fi
fi
rm -rf "${ARTIFACT_DIR}/audit-logs"
