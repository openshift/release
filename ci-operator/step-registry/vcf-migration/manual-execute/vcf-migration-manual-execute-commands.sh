#!/bin/bash

# Manual Day 2 vCenter migration, following the runbook that is the source of
# truth for ordering and wait conditions:
# https://github.com/openshift/vcf-migration-operator/blob/main/docs/user/day2-vcenter-migration.md
#
# Unlike vcf-migration-execute, this step never deploys the vcf-migration
# operator or creates a VmwareCloudFoundationMigration resource: it performs
# the runbook's steps directly against the cluster and the target vCenter.

set -o nounset
set -o errexit
set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export HOME="${HOME:-/tmp/home}"
mkdir -p "${HOME}"

# fetch_json runs "oc <args> -o json" and prints the result, or exits with
# code 2 when the API request itself fails so poll() can apply its
# consecutive-failure budget. Output is always taken from "-o json" and parsed
# with jq: "-o jsonpath" emits Go-syntax output that jq cannot parse.
function fetch_json() {
  local out
  if ! out="$(oc "$@" -o json 2>/dev/null)"; then
    return 2
  fi
  printf '%s\n' "${out}"
}

# poll <description> <deadline> <check function>
# Runs the check function every 30 seconds until it exits 0 or the deadline
# (a unix timestamp) passes. Exit code 0 means satisfied, exit code 2 means
# the API was unreachable and is tolerated for up to 25 consecutive attempts
# (during the control plane rollout the API server may be temporarily
# unreachable), and any other exit code means "not yet". Returns 1 on timeout
# or repeated API failure.
function poll() {
  local description="$1"
  local deadline="$2"
  local check="$3"
  local api_failures=0
  local max_api_failures=25
  local rc

  while (( $(date +%s) < deadline )); do
    if "${check}"; then
      log "${description}: satisfied"
      return 0
    else
      rc=$?
    fi

    if [[ "${rc}" -eq 2 ]]; then
      api_failures=$(( api_failures + 1 ))
      log "${description}: API request failed (${api_failures}/${max_api_failures}), retrying..."
      if (( api_failures >= max_api_failures )); then
        log "${description}: API unreachable for ${max_api_failures} consecutive attempts"
        return 1
      fi
    else
      api_failures=0
      log "${description}: not satisfied yet"
    fi

    sleep 30
  done

  log "${description}: timed out"
  return 1
}

# dump_cccmo_logs captures the operator that generates cloud-conf, not the
# pods consuming it (runbook Step 4).
function dump_cccmo_logs() {
  log "dumping cloud controller manager operator logs to ${ARTIFACT_DIR}"
  oc logs -n openshift-cloud-controller-manager-operator deploy/cluster-cloud-controller-manager-operator --tail=200 \
    > "${ARTIFACT_DIR}/cccmo-operator.log" 2>&1 || true
}

# dump_cpms_debug captures the ControlPlaneMachineSet and the state the
# runbook's Step 7 watch list calls for when the rollout is held.
function dump_cpms_debug() {
  log "dumping control plane debug information to ${ARTIFACT_DIR}"
  oc get controlplanemachineset cluster -n openshift-machine-api -o yaml \
    > "${ARTIFACT_DIR}/cpms.yaml" 2>&1 || true
  oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=master -o wide \
    > "${ARTIFACT_DIR}/cpms-master-machines.txt" 2>&1 || true
  oc get co > "${ARTIFACT_DIR}/clusteroperators.txt" 2>&1 || true
  oc get etcd cluster -o json | jq '.status.conditions' \
    > "${ARTIFACT_DIR}/etcd-conditions.json" 2>&1 || true
}

# strip_vcenter_entry <server> removes the "<server>:" subtree nested under
# "vcenter:" from the YAML configuration on stdin (runbook Step 9d). A
# "vcenter:" key left without children is removed as well; everything else —
# global:, labels:, nodes: — is passed through untouched.
function strip_vcenter_entry() {
  local server="$1"
  awk -v server="${server}" '
    {
      lines[NR] = $0
    }
    function indent_of(l) { return match(l, /[^[:space:]]/) - 1 }
    END {
      entry_indent = -1
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (entry_indent >= 0) {
          if (line ~ /^[[:space:]]*$/) { continue }
          if (indent_of(line) > entry_indent) { continue }
          entry_indent = -1
        }
        if (line ~ "^[[:space:]]+" server ":[[:space:]]*$") {
          entry_indent = indent_of(line)
          continue
        }
        print line
      }
    }
  ' | awk '
    {
      lines[NR] = $0
    }
    function indent_of(l) { return match(l, /[^[:space:]]/) - 1 }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (line ~ /^vcenter:[[:space:]]*$/) {
          j = i + 1
          while (j <= NR && lines[j] ~ /^[[:space:]]*$/) { j++ }
          if (j > NR || indent_of(lines[j]) == 0) { continue }
        }
        print line
      }
    }
  '
}

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

infra_id="$(oc get infrastructure cluster -o json | jq -r '.status.infrastructureName')"
if [[ -z "${infra_id}" || "${infra_id}" == "null" ]]; then
  log "failed to read the cluster infrastructure name"
  exit 1
fi
log "infrastructure id: ${infra_id}"

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc_target.sh"

log "runbook step 1a: region and zone tags"

# The categories have fixed names and single-value cardinality, and the
# attachments are asymmetric: the region tag goes on the datacenter, the zone
# tag on the compute cluster. Creation may fail when the category or tag
# already exists; the attachment check below is the gate.
while IFS= read -r fd; do
  region="$(jq -r '.region' <<< "${fd}")"
  zone="$(jq -r '.zone' <<< "${fd}")"
  datacenter="$(jq -r '.topology.datacenter' <<< "${fd}")"
  compute_cluster="$(jq -r '.topology.computeCluster' <<< "${fd}")"

  log "tagging datacenter ${datacenter} with region ${region} and compute cluster ${compute_cluster} with zone ${zone}"

  govc tags.category.create -t Datacenter -t ClusterComputeResource openshift-region || true
  govc tags.category.create -t Datacenter -t ClusterComputeResource openshift-zone || true
  govc tags.create -c openshift-region "${region}" || true
  govc tags.create -c openshift-zone "${zone}" || true

  govc tags.attach -c openshift-region "${region}" "/${datacenter}"
  govc tags.attach -c openshift-zone "${zone}" "${compute_cluster}"

  if ! govc tags.attached.ls -r "/${datacenter}" | grep -qx "${region}"; then
    log "region tag ${region} is not attached to /${datacenter}"
    exit 1
  fi
  if ! govc tags.attached.ls -r "${compute_cluster}" | grep -qx "${zone}"; then
    log "zone tag ${zone} is not attached to ${compute_cluster}"
    exit 1
  fi
done < <(jq -c '.[]' "${SHARED_DIR}/vcf-migration-target-fds.json")

log "runbook step 1b: VM folder and cluster ownership tag"

# Machines are cloned into /<datacenter>/vm/<infra-id>, and that folder
# carries the installer-style ownership tag. The folder and the category and
# tag may already exist; the attachment is the gate.
declare -A tagged_folders
while IFS= read -r fd; do
  datacenter="$(jq -r '.topology.datacenter' <<< "${fd}")"
  if [[ -n "${tagged_folders[${datacenter}]:-}" ]]; then
    continue
  fi
  tagged_folders["${datacenter}"]=1

  log "creating VM folder /${datacenter}/vm/${infra_id} with ownership tag"

  govc folder.create "/${datacenter}/vm/${infra_id}" || true
  govc tags.category.create -t urn:vim25:VirtualMachine -t urn:vim25:ResourcePool \
    -t urn:vim25:Folder -t urn:vim25:Datastore -t urn:vim25:StoragePod "openshift-${infra_id}" || true
  govc tags.create -c "openshift-${infra_id}" -d "Added by openshift-install do not remove" "${infra_id}" || true
  govc tags.attach -c "openshift-${infra_id}" "${infra_id}" "/${datacenter}/vm/${infra_id}"
done < <(jq -c '.[]' "${SHARED_DIR}/vcf-migration-target-fds.json")

log "runbook step 1c: RHCOS template"

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

log "runbook step 2: add credentials for the new vCenter"

# Credentials are added before the vCenter is registered so consumers can
# authenticate the first time they see it. Values are base64-encoded without
# a trailing newline; the patch adds the two keys and leaves the rest alone.
# The patch carries base64 credentials, so it is built in a protected file
# (umask 077) and applied with --patch-file: the values stay out of the
# oc patch arguments, the logs and any tracing, and are removed immediately
# after the patch. They are only transiently visible in the jq argument
# list within this step pod (runbook Step 2c).
[[ $- == *x* ]] && was_tracing=true || was_tracing=false
set +x  # Disable tracing due to credential handling
creds_patch_umask="$(umask)"
umask 077
creds_patch_file="$(mktemp)"
trap 'rm -f "${creds_patch_file}"' EXIT
jq -n \
  --arg server "${target_vcenter}" \
  --arg username "$(printf '%s' "${target_username}" | base64 | tr -d '\n')" \
  --arg password "$(printf '%s' "${target_password}" | base64 | tr -d '\n')" \
  '{
    data: {
      ($server + ".username"): $username,
      ($server + ".password"): $password
    }
  }' > "${creds_patch_file}"
oc patch secret vsphere-creds -n kube-system --type=merge --patch-file "${creds_patch_file}"
rm -f "${creds_patch_file}"
umask "${creds_patch_umask}"
if [[ "${was_tracing}" == "true" ]]; then
  set -x
fi

oc get secret vsphere-creds -n kube-system -o json \
  | jq -e --arg server "${target_vcenter}" '.data | has($server + ".username") and has($server + ".password")' >/dev/null

log "runbook step 3: register the new vCenter on the cluster"

oc get infrastructure cluster -o yaml > "${ARTIFACT_DIR}/infrastructure-backup.yaml"

# Record the source vCenters now: they drive credential removal and source
# cloud configuration cleanup in runbook Step 9.
infra_json="$(oc get infrastructure cluster -o json)"
source_vcenters_json="$(jq -c --arg target "${target_vcenter}" \
  '[.spec.platformSpec.vsphere.vcenters[].server | select(. != $target)]' <<< "${infra_json}")"
# vCenter hostnames are cluster infrastructure URLs; log a count and
# first-label fingerprints instead of the full names.
log "recorded $(jq 'length' <<< "${source_vcenters_json}") source vCenter(s) to retire: $(jq -r 'map(sub("\\..*"; "")) | join(", ")' <<< "${source_vcenters_json}")"

# Merge patches replace arrays wholesale, so the patch carries the existing
# entries plus the target ones. Networks stay as given in the rendered
# failure domains: the pre chain emits bare port group names, and Machine API
# and the ControlPlaneMachineSet resolve networks by object name.
infra_patch="$(jq -n \
  --arg server "${target_vcenter}" \
  --argjson fds "$(<"${rendered_fds}")" \
  --argjson current "${infra_json}" \
  '{
    spec: {
      platformSpec: {
        vsphere: {
          vcenters: ($current.spec.platformSpec.vsphere.vcenters
            + [{server: $server, port: 443, datacenters: ($fds | map(.topology.datacenter) | unique)}]),
          failureDomains: ($current.spec.platformSpec.vsphere.failureDomains + ($fds | map(del(.poolName))))
        }
      }
    }
  }')"
oc patch infrastructure cluster --type=merge -p "${infra_patch}"

oc get infrastructure cluster -o json \
  | jq -e --arg server "${target_vcenter}" '.spec.platformSpec.vsphere.vcenters | map(.server) | index($server) != null' >/dev/null

log "runbook step 4: wait for the cluster to pick up the new vCenter"

# cloud_conf_has_vcenter <server> checks whether the generated cloud-conf
# lists <server> under its vcenter section. The serialization of cloud.conf
# is not guaranteed to be JSON — the runbook reads it as YAML — so the JSON
# parse is tried first and a YAML read (yq-go, available in upi-installer)
# is the fallback. Exit codes follow poll(): 0 present, 1 absent, 2 API
# failure.
function cloud_conf_has_vcenter() {
  local server="$1"
  local cm_json conf_file conf_out server_re
  cm_json="$(fetch_json get cm cloud-conf -n openshift-cloud-controller-manager)" || return 2
  if jq -e --arg server "${server}" \
    '.data."cloud.conf" | fromjson | .vcenter | has($server)' <<< "${cm_json}" >/dev/null 2>&1; then
    return 0
  fi
  conf_file="$(mktemp)"
  jq -r '.data."cloud.conf" // ""' <<< "${cm_json}" > "${conf_file}"
  server_re="${server//./\\.}"
  # Capture the YAML read instead of piping it: under pipefail an
  # early-exiting grep can SIGPIPE the producer and turn a match into a
  # failure, and a failing producer would mask the grep result. A failed
  # read yields an empty string, which the grep treats as absent.
  conf_out="$(yq-go r "${conf_file}" 'vcenter' 2>/dev/null || true)"
  rm -f "${conf_file}"
  grep -qE "^[[:space:]]*${server_re}:[[:space:]]*$" <<< "${conf_out}"
}

function cloud_conf_has_target_vcenter() {
  cloud_conf_has_vcenter "${target_vcenter}"
}

# Nothing is restarted by hand: the components consuming the vSphere
# configuration either re-read it on every operation or redeploy themselves
# when the generated cloud-conf changes.
propagation_deadline=$(( $(date +%s) + 600 ))
if ! poll "generated cloud-conf contains target vCenter ${target_vcenter%%.*}" "${propagation_deadline}" cloud_conf_has_target_vcenter; then
  dump_cccmo_logs
  exit 1
fi

log "runbook step 5: add worker capacity on the new vCenter"

# This step maps every source worker MachineSet onto one target failure
# domain, mirroring the operator's inferred failure domain mapping, which is
# only valid for a single destination failure domain.
target_fd_count="$(jq 'length' "${rendered_fds}")"
if (( target_fd_count != 1 )); then
  log "expected exactly one target failure domain, found ${target_fd_count}; this step maps all worker MachineSets onto a single target failure domain"
  exit 1
fi
target_fd="$(jq -c '.[0]' "${rendered_fds}")"
target_fd_name="$(jq -r '.name' <<< "${target_fd}")"
sanitized_fd_name="$(printf '%s' "${target_fd_name}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "${sanitized_fd_name}" ]]; then
  sanitized_fd_name="default"
fi

fd_server="$(jq -r '.server // ""' <<< "${target_fd}")"
fd_datacenter="$(jq -r '.topology.datacenter // ""' <<< "${target_fd}")"
fd_compute_cluster="$(jq -r '.topology.computeCluster // ""' <<< "${target_fd}")"
fd_datastore="$(jq -r '.topology.datastore // ""' <<< "${target_fd}")"
fd_resource_pool="$(jq -r '.topology.resourcePool // ""' <<< "${target_fd}")"
fd_networks_json="$(jq -c '.topology.networks // []' <<< "${target_fd}")"
fd_template="$(jq -r '.topology.template // ""' <<< "${target_fd}")"

# Fail fast on an incomplete failure domain instead of building a MachineSet
# that fails to provision: jq prints the literal string "null" for a missing
# key, so every field is checked before it reaches a patch.
fd_missing_field=""
if [[ -z "${fd_server}" ]]; then
  fd_missing_field="server"
elif [[ -z "${fd_datacenter}" ]]; then
  fd_missing_field="topology.datacenter"
elif [[ -z "${fd_compute_cluster}" ]]; then
  fd_missing_field="topology.computeCluster"
elif [[ -z "${fd_datastore}" ]]; then
  fd_missing_field="topology.datastore"
elif [[ "$(jq 'length' <<< "${fd_networks_json}")" -eq 0 ]]; then
  fd_missing_field="topology.networks"
fi
if [[ -n "${fd_missing_field}" ]]; then
  log "target failure domain ${target_fd_name} is missing required field ${fd_missing_field}"
  exit 1
fi

# A default-pool failure domain carries no resourcePool; machines then use
# the compute cluster's default pool (runbook Step 5).
if [[ -z "${fd_resource_pool}" ]]; then
  fd_resource_pool="${fd_compute_cluster}/Resources"
  log "failure domain ${target_fd_name} has no resourcePool; using the compute cluster default pool"
fi

source_machinesets=()
created_machinesets=()
expected_workers=0
declare -A machineset_name_counts

# Machines are placed by the providerSpec, not by a failure domain field:
# each source worker MachineSet is copied with the placement rewritten from
# the target failure domain, keeping the source replica count so capacity is
# added, not shifted. Server-side fields are stripped because an object
# dumped with them applied back fails.
while IFS= read -r machineset_ref; do
  source_ms_name="${machineset_ref#machineset.machine.openshift.io/}"

  ms_json="$(oc get machineset "${source_ms_name}" -n openshift-machine-api -o json)"
  if [[ "$(jq -r '.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] // ""' <<< "${ms_json}")" == "master" ]]; then
    log "skipping master MachineSet ${source_ms_name}"
    continue
  fi
  source_machinesets+=("${source_ms_name}")

  replicas="$(jq -r '.spec.replicas // 0' <<< "${ms_json}")"

  base_name="${infra_id}-worker-${sanitized_fd_name}"
  name_count=$(( ${machineset_name_counts[${base_name}]:-0} + 1 ))
  machineset_name_counts["${base_name}"]="${name_count}"
  if (( name_count == 1 )); then
    target_ms_name="${base_name}"
  else
    target_ms_name="${base_name}-${name_count}"
  fi

  target_ms_json="$(jq \
    --arg name "${target_ms_name}" \
    --arg template "${fd_template}" \
    --arg server "${fd_server}" \
    --arg datacenter "${fd_datacenter}" \
    --arg datastore "${fd_datastore}" \
    --arg resourcePool "${fd_resource_pool}" \
    --arg folder "/${fd_datacenter}/vm/${infra_id}" \
    --argjson networks "${fd_networks_json}" \
    'del(.status, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)
    | .metadata.name = $name
    | .metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.spec.providerSpec.value.template = $template
    | .spec.template.spec.providerSpec.value.workspace = {
        server: $server,
        datacenter: $datacenter,
        datastore: $datastore,
        resourcePool: $resourcePool,
        folder: $folder
      }
    | .spec.template.spec.providerSpec.value.network.devices |=
      (to_entries | map(.value + {networkName: ($networks[.key] // $networks[0])}))' <<< "${ms_json}")"

  log "creating MachineSet ${target_ms_name} (${replicas} replicas) from ${source_ms_name}"
  tee "${ARTIFACT_DIR}/machineset-${target_ms_name}.json" <<< "${target_ms_json}" > /dev/null
  oc apply -f - <<< "${target_ms_json}"

  created_machinesets+=("${target_ms_name}")
  expected_workers=$(( expected_workers + replicas ))
done < <(oc get machineset -n openshift-machine-api -o name)

if [[ ${#created_machinesets[@]} -eq 0 ]]; then
  log "no source worker MachineSets found; nothing to re-provision"
  exit 1
fi
created_ms_json_array="$(printf '%s\n' "${created_machinesets[@]}" | jq -R . | jq -s .)"

function target_workers_ready() {
  local machines_json node_names_json nodes_json
  machines_json="$(fetch_json get machines -n openshift-machine-api)" || return 2
  if ! jq -e --argjson sets "${created_ms_json_array}" --argjson expected "${expected_workers}" '
      [.items[] | select(.metadata.labels["machine.openshift.io/cluster-api-machineset"] | IN($sets[]))] as $machines
      | ($machines | length) == $expected
      and ($machines | map(.status.nodeRef.name) | all(. != null))
      and ($machines | map(.status.conditions[]? | select(.type == "Ready") | .status) | all(. == "True"))' <<< "${machines_json}" >/dev/null; then
    return 1
  fi
  node_names_json="$(jq -c '[.items[] | .status.nodeRef.name] | map(select(. != null)) | unique' <<< "${machines_json}")"
  nodes_json="$(fetch_json get nodes)" || return 2
  jq -e --argjson names "${node_names_json}" '
    ([.items[] | select(.metadata.name | IN($names[]))] | length) == ($names | length)
    and ([.items[] | select(.metadata.name | IN($names[])) | .status.conditions[]? | select(.type == "Ready") | .status] | all(. == "True"))' <<< "${nodes_json}" >/dev/null
}

workers_deadline=$(( $(date +%s) + 1800 ))
if ! poll "target worker machines and nodes Ready" "${workers_deadline}" target_workers_ready; then
  exit 1
fi

log "runbook step 6: let the machine config pools settle"

# A master rebooting while control plane machines are being replaced is how
# etcd quorum is lost; wait until every pool has finished and nothing is
# degraded before touching the control plane.
oc wait --for=condition=Updated mcp/master --timeout=30m
oc wait --for=condition=Updated mcp/worker --timeout=30m
oc get mcp master worker -o json \
  | jq -e '[.items[] | .status.conditions[]? | select(.type == "Degraded") | .status] | all(. == "False")' >/dev/null

log "runbook step 7: move the control plane"

oc get controlplanemachineset cluster -n openshift-machine-api -o yaml > "${ARTIFACT_DIR}/cpms-backup.yaml"

cpms_json="$(oc get controlplanemachineset cluster -n openshift-machine-api -o json)"

# With OnDelete nothing is replaced automatically and the migration stalls
# after the update, leaving a half-moved control plane.
if ! jq -e '.spec.strategy.type != "OnDelete"' <<< "${cpms_json}" >/dev/null; then
  log "control plane machine set strategy is OnDelete; the control plane rollout would not proceed"
  exit 1
fi

# Removing the source failure domain is what forces every control plane
# machine to be replaced onto the target. Only the failure domain name is
# listed; the placement is filled in from the Infrastructure resource, so
# leftover source workspace values and networkName entries are dropped
# (placement comes from the failure domain once it is set, and leftover
# source values can be rejected on admission).
cpms_patch="$(jq \
  --argjson fds "$(<"${rendered_fds}")" \
  '(.spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value.network.devices // []) as $devices
    | {
      spec: {
        state: "Active",
        template: {
          machines_v1beta1_machine_openshift_io: {
            failureDomains: {platform: "VSphere", vsphere: ($fds | map({name: .name}))},
            spec: {
              providerSpec: {
                value: ({workspace: null}
                  + (if ($devices | length) > 0 then {network: {devices: ($devices | map(del(.networkName)))}} else {} end))
              }
            }
          }
        }
      }
    }' <<< "${cpms_json}")"
oc patch controlplanemachineset cluster -n openshift-machine-api --type=merge -p "${cpms_patch}"

function cpms_generation_observed() {
  local cpms_json
  cpms_json="$(fetch_json get controlplanemachineset cluster -n openshift-machine-api)" || return 2
  jq -e '(.status.observedGeneration // 0) >= .metadata.generation' <<< "${cpms_json}" >/dev/null
}

# cpms_degraded_since tracks when a Degraded/Error condition was first seen
# in the current episode; empty while none is present.
cpms_degraded_since=""

function cpms_rollout_complete() {
  local cpms_json condition now
  cpms_json="$(fetch_json get controlplanemachineset cluster -n openshift-machine-api)" || return 2
  # During a RollingUpdate replacement the new node registers with kubelet
  # before the machine controller links it to the replacement machine, which
  # reports a transient Degraded (typically UnmanagedNodes) that clears once
  # the mapping settles. A condition must therefore persist continuously for
  # 600 seconds before the rollout is treated as held; a genuinely held
  # rollout (a replacement that fails to provision) stays Degraded far
  # longer, so the runbook's abort-on-Degraded intent is preserved.
  condition="$(jq -r '
    [.status.conditions[]? | select((.type == "Degraded" or .type == "Error") and .status == "True")]
    | first
    | if . == null then "" else (.type + " reason=" + (.reason // "unknown") + " message=" + (.message // "unknown")) end' <<< "${cpms_json}")"
  if [[ -n "${condition}" ]]; then
    now="$(date +%s)"
    if [[ -z "${cpms_degraded_since}" ]]; then
      cpms_degraded_since="${now}"
      log "control plane machine set reports Degraded (${condition}); giving the rollout 600s to clear"
    fi
    if (( now - cpms_degraded_since >= 600 )); then
      log "control plane machine set has been Degraded for at least 600s (${condition}); the rollout is held"
      dump_cpms_debug
      exit 1
    fi
    return 1
  fi
  # A clean observation ends any Degraded episode: per-replacement flapping
  # must never abort while the rollout is progressing.
  cpms_degraded_since=""
  jq -e '
    (.status.observedGeneration // 0) >= .metadata.generation
    and (.status.replicas // 0) == (.spec.replicas // 3)
    and (.status.updatedReplicas // 0) == (.status.replicas // 0)
    and (.status.readyReplicas // 0) == (.status.replicas // 0)
    and (.status.replicas // 0) > 0' <<< "${cpms_json}" >/dev/null
}

cpms_deadline=$(( $(date +%s) + 5400 ))
if ! poll "control plane machine set generation observed" "${cpms_deadline}" cpms_generation_observed; then
  dump_cpms_debug
  exit 1
fi
if ! poll "control plane rollout complete" "${cpms_deadline}" cpms_rollout_complete; then
  dump_cpms_debug
  exit 1
fi

log "runbook step 8: remove the old worker capacity"

if [[ ${#source_machinesets[@]} -gt 0 ]]; then
  # Back up each source MachineSet while it still holds its replica count:
  # rollback needs the original object, and the dump must be taken before
  # scaling.
  for source_ms_name in "${source_machinesets[@]}"; do
    oc get machineset "${source_ms_name}" -n openshift-machine-api -o yaml \
      > "${ARTIFACT_DIR}/source-machineset-${source_ms_name}.yaml"
  done
  source_ms_json_array="$(printf '%s\n' "${source_machinesets[@]}" | jq -R . | jq -s .)"

  # Record the nodes the source machines own before scaling them down: the
  # wait below requires the nodes, not just the machines, to be gone.
  retired_node_names_json="$(oc get machines -n openshift-machine-api -o json | jq -c --argjson sets "${source_ms_json_array}" \
    '[.items[] | select(.metadata.labels["machine.openshift.io/cluster-api-machineset"] | IN($sets[])) | .status.nodeRef.name] | map(select(. != null)) | unique')"

  for source_ms_name in "${source_machinesets[@]}"; do
    oc scale machineset "${source_ms_name}" -n openshift-machine-api --replicas=0
  done

  function source_workers_gone() {
    local machines_json nodes_json
    machines_json="$(fetch_json get machines -n openshift-machine-api)" || return 2
    if ! jq -e --argjson sets "${source_ms_json_array}" \
        '[.items[] | select(.metadata.labels["machine.openshift.io/cluster-api-machineset"] | IN($sets[]))] | length == 0' <<< "${machines_json}" >/dev/null; then
      return 1
    fi
    nodes_json="$(fetch_json get nodes)" || return 2
    jq -e --argjson names "${retired_node_names_json}" \
      '[.items[] | select(.metadata.name | IN($names[]))] | length == 0' <<< "${nodes_json}" >/dev/null
  }

  source_removal_deadline=$(( $(date +%s) + 1800 ))
  if ! poll "source worker machines and nodes removed" "${source_removal_deadline}" source_workers_gone; then
    exit 1
  fi

  for source_ms_name in "${source_machinesets[@]}"; do
    oc delete machineset "${source_ms_name}" -n openshift-machine-api
  done
fi

log "runbook step 9: remove the old vCenter"

# Order matters: infrastructure first, then credentials, then wait for the
# change to propagate. The cluster refuses this while any Machine, MachineSet
# or ControlPlaneMachineSet still references the failure domain being
# removed, which is why runbook Steps 7 and 8 come first.
retire_patch="$(jq -n \
  --arg server "${target_vcenter}" \
  --argjson fds "$(<"${rendered_fds}")" \
  '{
    spec: {
      platformSpec: {
        vsphere: {
          vcenters: [{server: $server, port: 443, datacenters: ($fds | map(.topology.datacenter) | unique)}],
          failureDomains: ($fds | map(del(.poolName)))
        }
      }
    }
  }')"
oc patch infrastructure cluster --type=merge -p "${retire_patch}"

while IFS= read -r source_vcenter; do
  log "removing credentials for source vCenter ${source_vcenter%%.*}"
  oc patch secret vsphere-creds -n kube-system --type=merge \
    -p "$(jq -n --arg server "${source_vcenter}" '{data: {($server + ".username"): null, ($server + ".password"): null}}')"
done < <(jq -r '.[]' <<< "${source_vcenters_json}")

function cloud_conf_lacks_source_vcenters() {
  local source_vcenter rc
  while IFS= read -r source_vcenter; do
    # Capture the check's exit code in the else branch: after a bare if/fi
    # it would be the if statement's own status (zero), not the check's.
    if cloud_conf_has_vcenter "${source_vcenter}"; then
      return 1
    else
      rc=$?
    fi
    # Only a clean "absent" (rc 1) satisfies the retirement check: rc 2 is
    # an API failure (propagated for poll's failure budget), and any other
    # code means the check could not evaluate the generated configuration —
    # neither may count as retired.
    if [[ "${rc}" -eq 2 ]]; then
      return 2
    fi
    if [[ "${rc}" -ne 1 ]]; then
      return 1
    fi
  done < <(jq -r '.[]' <<< "${source_vcenters_json}")
  return 0
}

retire_deadline=$(( $(date +%s) + 600 ))
if ! poll "generated cloud-conf no longer lists source vCenters" "${retire_deadline}" cloud_conf_lacks_source_vcenters; then
  # On releases that do not rebuild the vCenter list from Infrastructure
  # alone, the source entry survives in cloud-provider-config; remove only
  # that entry and let the configuration regenerate (runbook Step 9d).
  log "source vCenter still listed in generated cloud-conf; removing its entry from cloud-provider-config"
  oc get cm cloud-provider-config -n openshift-config -o yaml > "${ARTIFACT_DIR}/cloud-provider-config-backup.yaml"
  while IFS= read -r source_vcenter; do
    new_config="$(oc get cm cloud-provider-config -n openshift-config -o json | jq -r '.data.config' | strip_vcenter_entry "${source_vcenter}")"
    oc patch cm cloud-provider-config -n openshift-config --type=merge \
      -p "$(jq -n --arg config "${new_config}" '{data: {config: $config}}')"
  done < <(jq -r '.[]' <<< "${source_vcenters_json}")

  retire_deadline=$(( $(date +%s) + 600 ))
  if ! poll "generated cloud-conf no longer lists source vCenters" "${retire_deadline}" cloud_conf_lacks_source_vcenters; then
    dump_cccmo_logs
    exit 1
  fi
fi

log "manual vCenter migration completed successfully"
