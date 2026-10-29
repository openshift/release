#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  log "using legacy sibling of this step"
  exit 0
fi

if [[ ! -f "${SHARED_DIR}/platform.json" ]]; then
  log "platform.json not found in ${SHARED_DIR}"
  exit 1
fi

if [[ ! -f "${SHARED_DIR}/govc.sh" ]]; then
  log "govc.sh not found in ${SHARED_DIR}"
  exit 1
fi

[[ $- == *x* ]] && was_tracing=true || was_tracing=false
set +x
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
if [[ "${was_tracing}" == "true" ]]; then
  set -x
fi

source_server="${GOVC_URL:-}"
if [[ -z "${source_server}" ]]; then
  log "GOVC_URL was not populated by govc.sh"
  exit 1
fi

log "source vCenter selected by check-vcm"

target_pool_name=""
target_server=""
for lease_json in "${SHARED_DIR}"/LEASE_*.json; do
  [[ "${lease_json}" =~ LEASE_single\.json$ ]] && continue

  pool_count=$(jq -r '.status.poolInfo | length' < "${lease_json}")
  if [[ "${pool_count}" == "null" || "${pool_count}" -eq 0 ]]; then
    continue
  fi

  for ((idx = 0; idx < pool_count; idx++)); do
    pool_server=$(jq -r ".status.poolInfo[${idx}].server" < "${lease_json}")
    [[ -z "${pool_server}" || "${pool_server}" == "null" ]] && continue

    if [[ "${pool_server}" == "${source_server}" ]]; then
      continue
    fi

    pool_name=$(jq -r ".status.poolInfo[${idx}].name" < "${lease_json}")
    if [[ -z "${target_pool_name}" ]]; then
      target_pool_name="${pool_name}"
      target_server="${pool_server}"
    elif [[ "${pool_server}" != "${target_server}" ]]; then
      log "multiple target vCenters discovered; this workflow expects exactly one target vCenter"
      exit 1
    fi
  done
done

if [[ -z "${target_pool_name}" || -z "${target_server}" ]]; then
  log "unable to determine a target pool distinct from the source vCenter"
  exit 1
fi

if [[ "${source_server}" == "${target_server}" ]]; then
  log "source and target vCenters are identical"
  exit 1
fi

pool_filename=$(echo "${target_pool_name}" | tr '.' '_' | tr ':' '_')
target_govc_file="${SHARED_DIR}/govc_${pool_filename}.sh"
if [[ ! -f "${target_govc_file}" ]]; then
  log "expected per-pool govc file ${target_govc_file} was not found"
  exit 1
fi

[[ $- == *x* ]] && was_tracing=true || was_tracing=false
set +x
# shellcheck source=/dev/null
source "${target_govc_file}"
target_username="${GOVC_USERNAME:-}"
target_password="${GOVC_PASSWORD:-}"
if [[ "${was_tracing}" == "true" ]]; then
  set -x
fi

if [[ -z "${target_username}" || -z "${target_password}" ]]; then
  log "target credentials were not populated from ${target_govc_file}"
  exit 1
fi

cp "${target_govc_file}" "${SHARED_DIR}/govc_target.sh"
printf '%s' "${target_server}" > "${SHARED_DIR}/vcf-migration-target-vcenter.txt"
jq -n \
  --arg username "${target_username}" \
  --arg password "${target_password}" \
  '{username: $username, password: $password}' > "${SHARED_DIR}/vcf-migration-target-creds.json"

jq --arg server "${source_server}" \
  '.failureDomains |= map(select(.server == $server))
   | .vcenters |= map(select(.server == $server))' \
  "${SHARED_DIR}/platform.json" > "${SHARED_DIR}/platform.filtered.json"

jq --arg server "${target_server}" \
  '[.failureDomains[] | select(.server == $server)]' \
  "${SHARED_DIR}/platform.json" > "${SHARED_DIR}/vcf-migration-target-fds.json"

source_fd_count=$(jq '.failureDomains | length' < "${SHARED_DIR}/platform.filtered.json")
target_fd_count=$(jq 'length' < "${SHARED_DIR}/vcf-migration-target-fds.json")

if [[ "${source_fd_count}" -eq 0 ]]; then
  log "filtered source platform spec is empty"
  exit 1
fi

if [[ "${target_fd_count}" -eq 0 ]]; then
  log "target failure domains are empty"
  exit 1
fi

mv "${SHARED_DIR}/platform.filtered.json" "${SHARED_DIR}/platform.json"

cat > ~/.jq <<'EOF'
def yamlify2:
    (objects | to_entries | (map(.key | length) | max + 2) as $w |
        .[] | (.value | type) as $type |
        if $type == "array" then
            "\(.key):", (.value | yamlify2)
        elif $type == "object" then
            "\(.key):", "    \(.value | yamlify2)"
        else
            "\(.key):\(" " * (.key | $w - length))\(.value)"
        end
    )
    // (arrays | select(length > 0)[] | [yamlify2] |
        "  - \(.[0])", "    \(.[1:][])"
    )
    // .
    ;
EOF

jq -r yamlify2 "${SHARED_DIR}/platform.json" | sed --expression='s/^/    /g' > "${SHARED_DIR}/platform.yaml"

log "wrote filtered install platform for source vCenter"
log "wrote ${target_fd_count} target failure domain(s)"
