#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

readonly MIGRATION_NAMESPACE="openshift-vcf-migration"
readonly MIGRATION_NAME="vcf-migration-e2e"
readonly MIGRATION_CRD="vmwarecloudfoundationmigrations.migration.openshift.io"
readonly OPERATOR_DEPLOYMENT="vcf-migration-operator-controller-manager"

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function debug_dump() {
  log "dumping migration debug information"
  oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" -o yaml || true
  oc -n "${MIGRATION_NAMESPACE}" describe "vmwarecloudfoundationmigration/${MIGRATION_NAME}" || true
  oc -n "${MIGRATION_NAMESPACE}" get events --sort-by='.lastTimestamp' || true
  oc -n "${MIGRATION_NAMESPACE}" logs "deployment/${OPERATOR_DEPLOYMENT}" --all-containers --tail=500 || true
}

function wait_for_condition() {
  local condition_type="$1"
  local deadline="$2"
  local api_failures=0
  local max_api_failures=25

  while (( $(date +%s) < deadline )); do
    # During control plane rollout the API server may be temporarily
    # unreachable (HAProxy/keepalive connection drops, TLS handshake
    # timeouts). Tolerate consecutive transient failures.
    local cr_json
    if ! cr_json="$(oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" -o json 2>/dev/null)"; then
      api_failures=$(( api_failures + 1 ))
      log "API request failed for condition ${condition_type} (${api_failures}/${max_api_failures}), retrying..."
      if (( api_failures >= max_api_failures )); then
        log "API unreachable for ${max_api_failures} consecutive attempts"
        debug_dump
        exit 1
      fi
      sleep 30
      continue
    fi

    api_failures=0
    condition_json="$(jq -c --arg type "${condition_type}" '.status.conditions[]? | select(.type == $type)' <<< "${cr_json}")"

    if [[ -n "${condition_json}" ]]; then
      status="$(jq -r '.status' <<< "${condition_json}")"
      reason="$(jq -r '.reason // ""' <<< "${condition_json}")"
      message="$(jq -r '.message // ""' <<< "${condition_json}")"
      log "condition ${condition_type}: status=${status} reason=${reason} message=${message}"

      if [[ "${status}" == "True" ]]; then
        return 0
      fi

      if [[ "${status}" == "False" && "${reason}" == "Failed" ]]; then
        log "condition ${condition_type} reported failure"
        debug_dump
        exit 1
      fi
    else
      log "condition ${condition_type} has not been reported yet"
    fi

    sleep 30
  done

  log "timed out waiting for condition ${condition_type}"
  debug_dump
  exit 1
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export HOME="${HOME:-/tmp/home}"
mkdir -p "${HOME}"

if [[ ! -f "${SHARED_DIR}/vcf-migration-target-fds.json" ]]; then
  log "target failure domains artifact missing"
  exit 1
fi

if [[ ! -f "${SHARED_DIR}/vcf-migration-target-creds.json" ]]; then
  log "target credentials artifact missing"
  exit 1
fi

if [[ ! -f "${SHARED_DIR}/vcf-migration-target-vcenter.txt" ]]; then
  log "target vCenter artifact missing"
  exit 1
fi

if [[ ! -f "${SHARED_DIR}/govc_target.sh" ]]; then
  log "target govc env artifact missing"
  exit 1
fi

target_vcenter="$(<"${SHARED_DIR}/vcf-migration-target-vcenter.txt")"
target_username="$(jq -r '.username' < "${SHARED_DIR}/vcf-migration-target-creds.json")"
target_password="$(jq -r '.password' < "${SHARED_DIR}/vcf-migration-target-creds.json")"
log "determining RHCOS OVA URL from release payload"
installer_bin="$(which openshift-install)"
ova_url="$("${installer_bin}" coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location')"
if [[ -z "${ova_url}" || "${ova_url}" == "null" ]]; then
  log "failed to determine OVA URL from release payload"
  exit 1
fi

vm_template="${ova_url##*/}"
log "using RHCOS OVA: ${ova_url}"
log "template name: ${vm_template}"

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc_target.sh"

# Import RHCOS OVA template into each target datacenter if not present
declare -A templates_by_datacenter
while IFS= read -r fd; do
  datacenter="$(jq -r '.topology.datacenter' <<< "${fd}")"
  datastore="$(jq -r '.topology.datastore' <<< "${fd}")"
  cluster="$(jq -r '.topology.computeCluster' <<< "${fd}")"
  network="$(jq -r '.topology.networks[0]' <<< "${fd}")"

  log "checking for template ${vm_template} in datacenter ${datacenter}"

  export GOVC_DATACENTER="${datacenter}"
  export GOVC_DATASTORE="${datastore}"
  export GOVC_RESOURCE_POOL="${cluster}/Resources"

  if [[ "$(govc vm.info "${vm_template}" 2>/dev/null | wc -c)" -eq 0 ]]; then
    log "importing OVA ${ova_url} into datacenter ${datacenter}"

    cat > /tmp/rhcos-import-${datacenter}.json <<EOF
{
  "DiskProvisioning": "thin",
  "MarkAsTemplate": false,
  "PowerOn": false,
  "InjectOvfEnv": false,
  "WaitForIP": false,
  "Name": "${vm_template}",
  "NetworkMapping": [{"Name": "VM Network", "Network": "${network}"}]
}
EOF

    curl -sL -o /tmp/rhcos.ova "${ova_url}"
    govc import.ova -options="/tmp/rhcos-import-${datacenter}.json" /tmp/rhcos.ova
    rm -f /tmp/rhcos.ova
  else
    log "template ${vm_template} already exists in datacenter ${datacenter}"
  fi

  template_path="/${datacenter}/vm/${vm_template}"
  templates_by_datacenter["${datacenter}"]="${template_path}"
  log "target datacenter ${datacenter} will use template ${template_path}"
done < <(jq -c '.[]' "${SHARED_DIR}/vcf-migration-target-fds.json")

rendered_fds="${ARTIFACT_DIR}/vcf-migration-target-fds.rendered.json"
cp "${SHARED_DIR}/vcf-migration-target-fds.json" "${rendered_fds}"
for datacenter in "${!templates_by_datacenter[@]}"; do
  jq \
    --arg datacenter "${datacenter}" \
    --arg template "${templates_by_datacenter[${datacenter}]}" \
    'map(
      if .topology.datacenter == $datacenter then
        .topology.template = $template
      else
        .
      end
    )' "${rendered_fds}" > "${rendered_fds}.tmp"
  mv "${rendered_fds}.tmp" "${rendered_fds}"
done

if jq -e 'map(select(.topology.template == null or .topology.template == "")) | length > 0' "${rendered_fds}" >/dev/null; then
  log "rendered failure domains are missing target templates"
  exit 1
fi

oc -n "${MIGRATION_NAMESPACE}" create secret generic target-vcenter-creds \
  --from-literal="${target_vcenter}.username=${target_username}" \
  --from-literal="${target_vcenter}.password=${target_password}" \
  --dry-run=client \
  -o yaml | oc apply -f -

oc wait --for=condition=Established --timeout=2m "crd/${MIGRATION_CRD}"

jq -n \
  --arg name "${MIGRATION_NAME}" \
  --arg namespace "${MIGRATION_NAMESPACE}" \
  --argfile failureDomains "${rendered_fds}" \
  '{
    apiVersion: "migration.openshift.io/v1alpha1",
    kind: "VmwareCloudFoundationMigration",
    metadata: {
      name: $name,
      namespace: $namespace
    },
    spec: {
      state: "Running",
      targetVCenterCredentialsSecret: {
        name: "target-vcenter-creds",
        namespace: $namespace
      },
      failureDomains: $failureDomains
    }
  }' | tee "${ARTIFACT_DIR}/vcf-migration-cr.json" | oc apply -f -

timeout_seconds="${VCF_MIGRATION_TIMEOUT}"
migration_deadline=$(( $(date +%s) + timeout_seconds ))
wait_for_condition "InfrastructurePrepared" "${migration_deadline}"
wait_for_condition "DestinationInitialized" "${migration_deadline}"
wait_for_condition "MultiSiteConfigured" "${migration_deadline}"
wait_for_condition "WorkloadMigrated" "${migration_deadline}"
wait_for_condition "SourceCleaned" "${migration_deadline}"
wait_for_condition "Ready" "${migration_deadline}"

log "migration completed successfully"
