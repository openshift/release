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

  while (( $(date +%s) < deadline )); do
    condition_json="$(oc -n "${MIGRATION_NAMESPACE}" get "vmwarecloudfoundationmigration/${MIGRATION_NAME}" -o json | jq -c --arg type "${condition_type}" '.status.conditions[]? | select(.type == $type)')"
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
infra_id="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"

if [[ -z "${infra_id}" ]]; then
  log "failed to determine infrastructure ID"
  exit 1
fi

source_template="$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o json | jq -r '.items[] | .spec.template.spec.providerSpec.value.template // empty' | sed '/^$/d' | sed -n '1p')"
if [[ -z "${source_template}" ]]; then
  log "failed to determine the source template from MachineSets"
  exit 1
fi

source_template_name="$(basename "${source_template}")"
log "discovered source template basename ${source_template_name}"

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc_target.sh"

declare -A templates_by_datacenter
mapfile -t target_datacenters < <(jq -r '.[].topology.datacenter' "${SHARED_DIR}/vcf-migration-target-fds.json" | sort -u)
for datacenter in "${target_datacenters[@]}"; do
  discovered_template="$(govc find "/${datacenter}/vm" -type m -name "${source_template_name}" | sed -n '1p')"
  if [[ -z "${discovered_template}" ]]; then
    log "failed to discover template ${source_template_name} in target datacenter ${datacenter}"
    exit 1
  fi
  templates_by_datacenter["${datacenter}"]="${discovered_template}"
  log "target datacenter ${datacenter} will use template ${discovered_template}"
done

rendered_fds="${ARTIFACT_DIR}/vcf-migration-target-fds.rendered.json"
cp "${SHARED_DIR}/vcf-migration-target-fds.json" "${rendered_fds}"
for datacenter in "${!templates_by_datacenter[@]}"; do
  jq \
    --arg datacenter "${datacenter}" \
    --arg template "${templates_by_datacenter[${datacenter}]}" \
    --arg infraID "${infra_id}" \
    'map(
      if .topology.datacenter == $datacenter then
        .topology.folder = (.topology.folder // ("/" + $datacenter + "/vm/" + $infraID))
        | .topology.template = $template
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
