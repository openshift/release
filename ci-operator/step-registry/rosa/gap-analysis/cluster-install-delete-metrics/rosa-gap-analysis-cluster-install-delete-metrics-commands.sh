#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

error(){
    echo -e "\033[1;31m$(date "+%d-%m-%YT%H:%M:%S") ERROR: " "${*}\033[0m" >&2
}

success(){
    echo -e "\033[1;32m$(date "+%d-%m-%YT%H:%M:%S") SUCCESS: " "${*}\033[0m" >&2
}

# Fetch "oc get <resource> -o json" into <dest>.
# Returns non-zero when the query fails or the payload is not a well-formed list
# of objects, so callers can distinguish "no problems found" from "could not
# look". The shape check covers every field the callers index, so a surprising
# payload fails validation instead of aborting the step under errexit:
#   - .metadata must be an object with a string .name;
#   - .status, when present, must be an object;
#   - .status.conditions, when present, must be an array of objects.
# Without those clauses a non-object .status, a non-object condition entry or a
# non-object .metadata makes the health jq below exit non-zero, and errexit then
# kills the step before any result is recorded, while a non-array
# .status.conditions is silently skipped by `[]?` and reads as healthy.
# An absent or empty .status.conditions is well-formed and accepted here; the
# health checks treat it as unverified rather than healthy. A condition that
# IS supplied must carry one of the three statuses the API defines, as a
# string: a JSON boolean true matches no selector, so a Degraded=true operator
# would otherwise read as healthy. Its .type must likewise be a nonempty
# string, for the same reason in the other direction: a condition the
# selectors cannot name is one they silently skip, so an Available=True
# sibling would carry the whole verdict. Unfamiliar type names are accepted;
# the API only requires that the field be a string. An absent list and a
# present but malformed condition stay distinct -- the first is unverified,
# the second is rejected.
# -s with `length == 1` because a concatenation of several documents parses
# fine one document at a time: the shape check would pass on each while the
# counts and health lists below silently read all of them.
# A name must be a nonempty string: the health selectors emit the name, and an
# empty one is dropped by command substitution, so an unhealthy resource would
# disappear from the list it belongs in.
# Client errors are discarded rather than captured: they can carry the cluster
# API endpoint, and <dest> is only ever written with a well-formed payload.
get_resource_json(){
    local resource="$1" dest="$2"
    oc get "${resource}" -o json --request-timeout=60s > "${dest}" 2>/dev/null || return 1
    jq -es 'length == 1 and (.[0]
           | has("items") and (.items | type == "array") and all(.items[];
             type == "object"
             and (.metadata | type) == "object"
             and (.metadata.name | type) == "string"
             and (.metadata.name | length) > 0
             and ((.status | type) as $s
                  | $s == "null"
                    or ($s == "object"
                        and ((.status.conditions | type) as $c
                             | $c == "null"
                               or ($c == "array"
                                   and all(.status.conditions[];
                                         type == "object"
                                         and (.type | type) == "string"
                                         and (.type | length) > 0
                                         and (.status == null
                                              or .status == "True"
                                              or .status == "False"
                                              or .status == "Unknown"))))))
           ))' \
      "${dest}" >/dev/null 2>&1 || return 1
}

# Names the items that do not assert health through $condition ("Ready" for
# nodes, "Available" for ClusterOperators). Health is asserted, never assumed:
# an item is healthy only when it reports that condition and every occurrence
# of it is "True", so a missing status, an empty or absent condition list, a
# "False"/"Unknown" status and a contradicting duplicate all read as unhealthy.
# Shared so the report and the snapshot artifact cannot drift apart.
# Use as: jq -r --arg condition Ready "${UNHEALTHY_BY_CONDITION}" <file>
UNHEALTHY_BY_CONDITION='.items[]?
  | select([.status.conditions[]? | select(.type == $condition) | .status]
           | (length > 0 and all(. == "True")) | not)
  | .metadata.name'

# jq helpers for the snapshot projections. Each collapses every condition of a
# type down to one status, so a projected field cannot disagree with the health
# lists above and re-ordering an item's conditions cannot change the result:
#   all_true_status - "True" only when the type is reported and every
#                     occurrence is "True". Used for Ready and Available, the
#                     conditions that have to assert health; it is the same
#                     rule as UNHEALTHY_BY_CONDITION, so the projected value
#                     and the unhealthy lists always agree.
#   any_true_status - "True" when any occurrence is "True", so a reported
#                     problem is never masked. Used for Degraded and
#                     Progressing, where "True" is the noteworthy value.
# Both yield "" when the type is not reported at all, and otherwise a status
# the item actually reported, keeping the existing "True"/"False"/"Unknown"/""
# value domain of these fields.
SNAPSHOT_CONDITION_HELPERS='
  def as_status: if type == "string" then . else "" end;
  def condition_statuses($type):
    [.status.conditions[]? | select(.type == $type) | .status];
  # Fixed precedence, so the projected value never depends on the order the
  # conditions happen to appear in: a reported "False" outranks an "Unknown",
  # which outranks anything else, and the remainder is sorted to stay
  # deterministic. Without this, reversing two conditions changes nodes.json.
  def worst_status:
    if length == 0 then ""
    elif any(. == "False") then "False"
    elif any(. == "Unknown") then "Unknown"
    else (map(as_status) | sort | first)
    end;
  def all_true_status($type):
    condition_statuses($type)
    | if length == 0 then ""
      elif all(. == "True") then "True"
      else (map(select(. != "True")) | worst_status)
      end;
  def any_true_status($type):
    condition_statuses($type)
    | if length == 0 then ""
      elif any(. == "True") then "True"
      else worst_status
      end;
'

# Fetch a snapshot payload with the same validation the report uses, and also
# require it to be nonempty. The report phase already refuses to call an empty
# ClusterOperator or node list healthy; a snapshot that published an empty list
# with a verified flag would assert exactly what the report refuses to.
get_snapshot_json(){
    local resource="$1" dest="$2" count
    get_resource_json "${resource}" "${dest}" || return 1
    # Checked assignment, not a comparison on a substitution: jq can print a
    # number and still exit non-zero, and the numeric test alone would accept
    # that as a verified count.
    count="$(jq -r '.items | length' "${dest}")" || return 1
    # Defensive and deliberately not reachable from a payload get_resource_json
    # accepts: it only matters if jq ever exits zero with something other than
    # an integer.
    [[ "${count}" =~ ^[0-9]+$ ]] || return 1
    [[ "${count}" -gt 0 ]] || return 1
}

# Configure cloud credentials. OSD GCP does not use AWS.
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ "${CLUSTER_TOPOLOGY:-}" == "osd-gcp" ]]; then
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE:-}}"
  log "OSD GCP cluster; skipping AWS credential setup"
elif [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE:-}}"
  if [[ -z "${AWS_DEFAULT_REGION}" ]]; then
    error "No AWS region: set REGION or LEASED_RESOURCE"
    exit 1
  fi
else
  error "No AWS credentials found in cluster profile"
  exit 1
fi

# Log into OCM
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  error "No OCM credentials found in cluster profile"
  exit 1
fi

# Get cluster info
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Running gap-analysis validation for cluster: ${CLUSTER_ID}"

if [[ "${HOSTED_CP:-false}" == "true" ]]; then
  topology="hcp"
elif [[ "${CLUSTER_TOPOLOGY:-}" == "osd-gcp" ]]; then
  topology="osd-gcp"
else
  topology="classic"
fi

DIAG_DIR="${ARTIFACT_DIR}/diagnostics"
mkdir -p "${DIAG_DIR}"

# Scratch space for validation working files. These hold raw API payloads and
# client errors, which can carry node addresses, provider IDs and the cluster
# API endpoint, so they must not land in the published artifact directory.
VALIDATION_SCRATCH="$(mktemp -d)"
trap 'rm -rf "${VALIDATION_SCRATCH}"' EXIT

# Write a placeholder into a capture file whose own write may fail -- the path
# can be a directory or otherwise unwritable. Reporting the retrieval failure,
# taking the snapshot and writing the summary all matter more than the
# placeholder, so a failed write here is noted and never aborts the step.
write_capture_placeholder(){
  local dest="$1" text="$2"
  if ! echo "${text}" > "${dest}"; then
    error "Could not write the placeholder capture file ${dest}"
  fi
}

# Run a diagnostic collection into a published file, keeping its stderr out of
# the artifact. A client error names the cluster API endpoint, and these
# collections previously folded stderr into the artifact with 2>&1, so a
# cluster that stayed unreachable published the endpoint in every diagnostic.
# Successful output is still captured in full; on failure the artifact records
# only a sanitized line and the real error stays in the scratch directory.
collect_diagnostic(){
  local dest="$1"; shift
  local status=0
  "$@" > "${dest}" 2>"${VALIDATION_SCRATCH}/diagnostic.err" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    # Appended, not substituted: whatever the command managed to print before
    # failing is still useful, and the leak was only ever on stderr.
    printf '(unavailable: %s exited %s)\n' "${1}" "${status}" >> "${dest}"
  fi
  return "${status}"
}

# Initialize validation report
INSTALL_REPORT="${DIAG_DIR}/gap-analysis-cluster-install-report.txt"

cat > "${INSTALL_REPORT}" <<EOF
========================================
ROSA Gap Analysis Cluster Install Report
========================================
Cluster ID: ${CLUSTER_ID}
Region: ${AWS_DEFAULT_REGION}
Test Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
========================================

EOF

VALIDATION_FAILED=0

# Verify cluster exists via OCM API
log "Verifying cluster exists..."
if ! ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}" &>/dev/null; then
  error "Failed to get cluster ${CLUSTER_ID} from OCM API"
  exit 1
fi

KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

# Use existing kubeconfig if present (created by rosa-conf-idp-htpasswd in PRE phase)
if [[ -f "${KUBECONFIG_FILE}" ]]; then
  log "Using existing admin kubeconfig from PRE phase"
  export KUBECONFIG="${KUBECONFIG_FILE}"
else
  # Fallback: fetch kubeconfig via OCM API
  log "No existing kubeconfig found, fetching from OCM API..."
  ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/credentials 2>/dev/null | jq -r '.kubeconfig' > "${KUBECONFIG_FILE}" || {
    error "Failed to fetch kubeconfig via OCM API"
    exit 1
  }
  export KUBECONFIG="${KUBECONFIG_FILE}"
fi

# Validate kubeconfig
if ! oc whoami &>/dev/null; then
  error "Failed to authenticate with cluster kubeconfig"
  exit 1
fi

log "Successfully authenticated with cluster"

###########################################
# Validation 1: Validate ClusterOperators
###########################################
log "Validation 1: Validating ClusterOperators..."
echo "" >> "${INSTALL_REPORT}"
echo "1. ClusterOperators Status" >> "${INSTALL_REPORT}"
echo "--------------------------" >> "${INSTALL_REPORT}"

CO_OUTPUT="${DIAG_DIR}/clusteroperators.txt"
CO_JSON="${VALIDATION_SCRATCH}/clusteroperators.json"
CO_WIDE_OK=1
# Client errors go to scratch, not to the published capture file: they routinely
# name the cluster API endpoint.
if oc get co -o wide > "${CO_OUTPUT}" 2>"${VALIDATION_SCRATCH}/co-wide.err"; then
  cat "${CO_OUTPUT}" >> "${INSTALL_REPORT}"
  echo "" >> "${INSTALL_REPORT}"
else
  CO_WIDE_OK=0
  write_capture_placeholder "${CO_OUTPUT}" "(ClusterOperator listing unavailable)"
  error "Failed to get ClusterOperators"
  echo "Status: FAILED (unable to retrieve ClusterOperators)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
fi

if ! get_resource_json co "${CO_JSON}"; then
  error "Failed to query ClusterOperators as JSON; operator health is unverified"
  echo "Status: FAILED (ClusterOperator JSON query failed or returned malformed data)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
else
  # Check for degraded or unavailable operators.
  # Availability is asserted, never assumed: an operator counts as available
  # only when it reports Available and every Available condition it reports is
  # True. Available=False, Available=Unknown and a missing Available condition
  # are all unverified, and an unverified operator is reported rather than
  # passed. Collecting the statuses rather than asking for a single matching
  # condition also keeps a contradicting Available=False from being masked by a
  # duplicate Available=True.
  # Checked assignments, tracked per query. Under errexit a failing jq here
  # would kill the step mid-report, leaving no failure reason, no summary and
  # no snapshot; recording the section as unverified instead lets the run
  # reach the remaining diagnostics and the final FAILED summary. Per query,
  # because one failure must not discard what the others established: an
  # operator a successful query proved Degraded stays in the report and still
  # gets its `oc describe` diagnostics. There is no healthy fallback.
  CO_COUNT_READ=true
  CO_DEGRADED_READ=true
  CO_UNAVAILABLE_READ=true
  CO_COUNT=$(jq -r '.items | length' "${CO_JSON}") || CO_COUNT_READ=false
  DEGRADED_CO=$(jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | .metadata.name' "${CO_JSON}") || CO_DEGRADED_READ=false
  UNAVAILABLE_CO=$(jq -r --arg condition Available "${UNHEALTHY_BY_CONDITION}" "${CO_JSON}") || CO_UNAVAILABLE_READ=false
  CO_HEALTH_READ=true
  if [[ "${CO_COUNT_READ}" != true || "${CO_DEGRADED_READ}" != true || "${CO_UNAVAILABLE_READ}" != true ]]; then
    CO_HEALTH_READ=false
    # Only the output of the query that failed is discarded.
    [[ "${CO_COUNT_READ}" == true ]] || CO_COUNT=0
    [[ "${CO_DEGRADED_READ}" == true ]] || DEGRADED_CO=""
    [[ "${CO_UNAVAILABLE_READ}" == true ]] || UNAVAILABLE_CO=""
    error "Failed to evaluate ClusterOperator health; operator health is unverified"
    echo "Status: FAILED (ClusterOperator health could not be evaluated)" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ -n "${DEGRADED_CO}" ]]; then
    error "Degraded ClusterOperators found: ${DEGRADED_CO}"
    echo "Degraded Operators: ${DEGRADED_CO}" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ -n "${UNAVAILABLE_CO}" ]]; then
    error "Unavailable ClusterOperators found: ${UNAVAILABLE_CO}"
    echo "Unavailable Operators: ${UNAVAILABLE_CO}" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ "${CO_HEALTH_READ}" != true ]]; then
    : # already reported and failed above
  elif [[ "${CO_COUNT}" -eq 0 ]]; then
    # An empty operator list is absence of evidence, not evidence of health.
    error "ClusterOperator query returned no operators; operator health is unverified"
    echo "Status: FAILED (no ClusterOperators returned)" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  elif [[ -n "${DEGRADED_CO}" || -n "${UNAVAILABLE_CO}" ]]; then
    : # already reported and failed above
  elif [[ "${CO_WIDE_OK}" -eq 1 ]]; then
    success "All ClusterOperators are healthy"
    echo "All operators: HEALTHY" >> "${INSTALL_REPORT}"
  fi
fi

###########################################
# Validation 2: Validate nodes
###########################################
log "Validation 2: Validating nodes..."
echo "" >> "${INSTALL_REPORT}"
echo "2. Nodes Status" >> "${INSTALL_REPORT}"
echo "---------------" >> "${INSTALL_REPORT}"

NODES_OUTPUT="${DIAG_DIR}/nodes.txt"
NODES_JSON="${VALIDATION_SCRATCH}/nodes.json"
NODES_WIDE_OK=1
# As above: keep the raw client error out of the published capture file.
if oc get nodes -o wide > "${NODES_OUTPUT}" 2>"${VALIDATION_SCRATCH}/nodes-wide.err"; then
  cat "${NODES_OUTPUT}" >> "${INSTALL_REPORT}"
  echo "" >> "${INSTALL_REPORT}"
else
  NODES_WIDE_OK=0
  write_capture_placeholder "${NODES_OUTPUT}" "(node listing unavailable)"
  error "Failed to get nodes"
  echo "Status: FAILED (unable to retrieve nodes)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
fi

if ! get_resource_json nodes "${NODES_JSON}"; then
  error "Failed to query nodes as JSON; node health is unverified"
  echo "Status: FAILED (node JSON query failed or returned malformed data)" >> "${INSTALL_REPORT}"
  VALIDATION_FAILED=1
else
  # Check for NotReady nodes. Readiness is asserted, never assumed: see
  # UNHEALTHY_BY_CONDITION above.
  # Checked assignments, for the same reason as the ClusterOperator reads.
  NODE_COUNT_READ=true
  NODE_NOTREADY_READ=true
  NODE_COUNT=$(jq -r '.items | length' "${NODES_JSON}") || NODE_COUNT_READ=false
  NOTREADY_NODES=$(jq -r --arg condition Ready "${UNHEALTHY_BY_CONDITION}" "${NODES_JSON}") || NODE_NOTREADY_READ=false
  NODE_HEALTH_READ=true
  if [[ "${NODE_COUNT_READ}" != true || "${NODE_NOTREADY_READ}" != true ]]; then
    NODE_HEALTH_READ=false
    # As above: keep whatever a successful query established.
    [[ "${NODE_COUNT_READ}" == true ]] || NODE_COUNT=0
    [[ "${NODE_NOTREADY_READ}" == true ]] || NOTREADY_NODES=""
    error "Failed to evaluate node health; node health is unverified"
    echo "Status: FAILED (node health could not be evaluated)" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ -n "${NOTREADY_NODES}" ]]; then
    error "NotReady nodes found: ${NOTREADY_NODES}"
    echo "NotReady Nodes: ${NOTREADY_NODES}" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  fi

  if [[ "${NODE_HEALTH_READ}" != true ]]; then
    : # already reported and failed above
  elif [[ "${NODE_COUNT}" -eq 0 ]]; then
    # An empty node list is absence of evidence, not evidence of health.
    error "Node query returned no nodes; node health is unverified"
    echo "Status: FAILED (no nodes returned)" >> "${INSTALL_REPORT}"
    VALIDATION_FAILED=1
  elif [[ -n "${NOTREADY_NODES}" ]]; then
    : # already reported and failed above
  elif [[ "${NODES_WIDE_OK}" -eq 1 ]]; then
    success "All nodes are Ready"
    echo "All nodes: READY" >> "${INSTALL_REPORT}"
  fi

  # Count nodes (from the same payload the health check used). A count that
  # could not be evaluated is reported as such: "Total nodes: 0" is the exact
  # fingerprint of the false-success this step exists to prevent.
  # Gated on the count query alone: a count that was read stays reported even
  # when another health query failed, which is the point of tracking the
  # queries separately. Only an uncounted cluster reads "unverified"; it must
  # never read "Total nodes: 0", the fingerprint of the original false success.
  if [[ "${NODE_COUNT_READ}" == true ]]; then
    echo "Total nodes: ${NODE_COUNT}" >> "${INSTALL_REPORT}"
  else
    echo "Total nodes: unverified" >> "${INSTALL_REPORT}"
  fi
fi

###########################################
# Collect cluster logs (always)
# HCP control-plane pods live on the management cluster in HCP_NAMESPACE.
# Guest-side openshift-cluster-version / kube-apiserver / etcd are empty on HCP.
###########################################
log "Collecting cluster logs and diagnostics..."
echo "" >> "${INSTALL_REPORT}"
echo "3. Cluster Logs and Diagnostics" >> "${INSTALL_REPORT}"
echo "--------------------------------" >> "${INSTALL_REPORT}"

if [[ "${topology}" != "hcp" ]]; then
  log "Collecting cluster-version operator logs..."
  collect_diagnostic "${DIAG_DIR}/cvo-logs.txt" oc logs deployment/cluster-version-operator -n openshift-cluster-version --tail=500 || true
fi

if [[ -n "${DEGRADED_CO:-}" ]]; then
  for co in ${DEGRADED_CO}; do
    log "Collecting logs for degraded operator: ${co}"
    collect_diagnostic "${DIAG_DIR}/co-${co}-describe.txt" oc describe co "${co}" || true
  done
fi

if [[ "${topology}" == "hcp" ]]; then
  log "HCP guest: collecting worker-side monitoring pods (control plane is on the management cluster)"
  collect_diagnostic "${DIAG_DIR}/pods-openshift-monitoring.txt" oc get pods -n openshift-monitoring -o wide || true
else
  for ns in openshift-cluster-version openshift-kube-apiserver openshift-etcd openshift-monitoring; do
    log "Collecting pod status from namespace: ${ns}"
    collect_diagnostic "${DIAG_DIR}/pods-${ns}.txt" oc get pods -n "${ns}" -o wide || true
  done
fi

echo "Cluster logs collected in ${DIAG_DIR}/" >> "${INSTALL_REPORT}"

###########################################
# Structured snapshot for rosa-gap-analysis Check #11
###########################################

ensure_management_cluster_ids() {
  if [[ -f "${SHARED_DIR}/mc-cluster-name" && -f "${SHARED_DIR}/mc-cluster-id" ]]; then
    return 0
  fi
  local mc_name mc_id
  mc_name="$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" | jq -r '.management_cluster')" || return 0
  if [[ -z "${mc_name}" || "${mc_name}" == "null" ]]; then
    return 0
  fi
  echo "${mc_name}" > "${SHARED_DIR}/mc-cluster-name"
  mc_id="$(ocm get /api/clusters_mgmt/v1/clusters --parameter "search=name is '${mc_name}'" | jq -r '.items[0].id')" || return 0
  if [[ -n "${mc_id}" && "${mc_id}" != "null" ]]; then
    echo "${mc_id}" > "${SHARED_DIR}/mc-cluster-id"
  fi
}

resolve_management_kubeconfig() {
  local mc_file="${SHARED_DIR}/hs-mc.kubeconfig"
  if [[ -f "${mc_file}" ]]; then
    log "Using management kubeconfig from ${mc_file}"
    ensure_management_cluster_ids
    export KUBECONFIG="${mc_file}"
    return 0
  fi
  log "Resolving management cluster for hosted cluster ${CLUSTER_ID}"
  local mc_name mc_id
  mc_name="$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" | jq -r '.management_cluster')" || return 1
  mc_id="$(ocm get /api/clusters_mgmt/v1/clusters --parameter "search=name is '${mc_name}'" | jq -r '.items[0].id')" || return 1
  if [[ -z "${mc_id}" || "${mc_id}" == "null" ]]; then
    error "Failed to get management cluster id for ${mc_name}"
    return 1
  fi
  echo "${mc_name}" > "${SHARED_DIR}/mc-cluster-name"
  echo "${mc_id}" > "${SHARED_DIR}/mc-cluster-id"
  log "Fetching management kubeconfig for ${mc_name} (${mc_id})"
  ocm get "/api/clusters_mgmt/v1/clusters/${mc_id}/credentials" | jq -r '.kubeconfig' > "${mc_file}" || return 1
  export KUBECONFIG="${mc_file}"
}

# Hosted control plane namespace on the management cluster:
#   HC_NAMESPACE  = ocm-<env>-<hosted CLUSTER_ID>
#   HCP_NAMESPACE = ocm-<env>-<hosted CLUSTER_ID>-<DOMAIN_PREFIX>
# env is OCM_LOGIN_ENV (staging/production). DOMAIN_PREFIX comes from the hosted cluster.
resolve_hcp_namespaces() {
  local cluster_info domain_prefix
  cluster_info="$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}")" || return 1
  domain_prefix="$(echo "${cluster_info}" | jq -r '.domain_prefix // empty')"
  if [[ -z "${domain_prefix}" || "${domain_prefix}" == "null" ]]; then
    if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
      domain_prefix="$(head -n 1 "${SHARED_DIR}/cluster-name")"
    else
      domain_prefix="$(echo "${cluster_info}" | jq -r '.name')"
    fi
  fi
  if [[ -z "${domain_prefix}" || "${domain_prefix}" == "null" ]]; then
    error "Failed to resolve hosted cluster domain prefix for ${CLUSTER_ID}"
    return 1
  fi
  HC_NAMESPACE="ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}"
  HCP_NAMESPACE="ocm-${OCM_LOGIN_ENV}-${CLUSTER_ID}-${domain_prefix}"
  log "HC namespace:  ${HC_NAMESPACE}"
  log "HCP namespace: ${HCP_NAMESPACE}"
}

collect_hcp_control_plane_diagnostics() {
  if ! resolve_hcp_namespaces; then
    return 0
  fi
  mkdir -p "${DIAG_DIR}"
  log "Collecting hosted control-plane pods from management cluster namespace ${HCP_NAMESPACE}"
  collect_diagnostic "${DIAG_DIR}/hostedcluster.txt" oc get hostedcluster -n "${HC_NAMESPACE}" -o wide || true
  collect_diagnostic "${DIAG_DIR}/hostedcontrolplane.txt" oc get hostedcontrolplane -n "${HCP_NAMESPACE}" -o wide || true
  collect_diagnostic "${DIAG_DIR}/pods-hcp-namespace.txt" oc get pods -n "${HCP_NAMESPACE}" -o wide || true
  collect_diagnostic "${DIAG_DIR}/cvo-logs.txt" \
    oc logs deployment/cluster-version-operator -n "${HCP_NAMESPACE}" --tail=500 || \
    collect_diagnostic "${DIAG_DIR}/cvo-logs.txt" \
      oc logs -n "${HCP_NAMESPACE}" -l app=cluster-version-operator --tail=500 || true
  echo "HCP namespace ${HCP_NAMESPACE} pods collected from management cluster" >> "${INSTALL_REPORT}"
}

write_install_snapshot() {
  local cluster_role="$1"
  local snapshot_dir="$2"
  local overall_status="$3"
  mkdir -p "${snapshot_dir}"

  local cluster_version=""
  cluster_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' --request-timeout=30s 2>/dev/null || true)"
  # Checked reads: an absent identity file is normal and stays accepted, but a
  # present file that cannot be read must fail the capture. Both call sites
  # invoke this function with errexit suppressed, so an unchecked `cat` would
  # leave the identity empty and let a PASSED snapshot be published anyway.
  local mgmt_name="" mgmt_id=""
  if [[ -f "${SHARED_DIR}/mc-cluster-name" ]]; then
    if ! mgmt_name="$(cat "${SHARED_DIR}/mc-cluster-name")"; then
      error "${cluster_role}: could not read mc-cluster-name; refusing to publish metadata"
      rm -f "${snapshot_dir}/metadata.json"
      return 1
    fi
  fi
  if [[ -f "${SHARED_DIR}/mc-cluster-id" ]]; then
    if ! mgmt_id="$(cat "${SHARED_DIR}/mc-cluster-id")"; then
      error "${cluster_role}: could not read mc-cluster-id; refusing to publish metadata"
      rm -f "${snapshot_dir}/metadata.json"
      return 1
    fi
  fi

  # Snapshot payloads go through the same validation as the report. A snapshot
  # query that fails, or returns a payload the health jq cannot be trusted to
  # index, must not publish empty health arrays and a zero count beside an
  # unchanged overall_status: that reads as a clean cluster. The raw payloads
  # stay in the scratch directory, never in the published snapshot directory,
  # because they carry node addresses and provider IDs. Each role fetches its
  # own copy, so the management-cluster snapshot keeps its own kubeconfig
  # context instead of reusing the hosted cluster's data.
  local co_snapshot_json="${VALIDATION_SCRATCH}/${cluster_role}-snapshot-co.json"
  local nodes_snapshot_json="${VALIDATION_SCRATCH}/${cluster_role}-snapshot-nodes.json"
  local operators_verified=true nodes_verified=true
  get_snapshot_json co "${co_snapshot_json}" || operators_verified=false
  get_snapshot_json nodes "${nodes_snapshot_json}" || nodes_verified=false

  # Counted from the validated payload the health lists were derived from, so
  # the count cannot come from a different read than the names beside it.
  local node_count=0
  if [[ "${nodes_verified}" == true ]]; then
    # A count that cannot be computed is not a count of zero: falling back to 0
    # while still claiming the nodes were verified publishes "no nodes" for a
    # cluster that was never counted.
    node_count="$(jq -r '.items | length' "${nodes_snapshot_json}")" || nodes_verified=false
    if [[ ! "${node_count}" =~ ^[0-9]+$ ]]; then
      node_count=0
      nodes_verified=false
    fi
  fi

  local snapshot_cluster_id snapshot_openshift_version
  snapshot_cluster_id="${CLUSTER_ID}"
  snapshot_openshift_version="${OPENSHIFT_VERSION:-}"
  if [[ "${cluster_role}" == "management" ]]; then
    snapshot_cluster_id="${mgmt_id:-${CLUSTER_ID}}"
    if [[ "${cluster_version}" =~ ^([0-9]+\.[0-9]+) ]]; then
      snapshot_openshift_version="${BASH_REMATCH[1]}"
    fi
  fi

  # The snapshot uses the same assert-health predicate as the report above, so
  # the machine-readable artifact cannot disagree with the human report about
  # which operators and nodes were verified. An unverified resource contributes
  # no names; the *_verified flags below say so explicitly rather than letting
  # the empty list read as "nothing wrong".
  log "Writing cluster install snapshot role=${cluster_role} topology=${topology} cluster_id=${snapshot_cluster_id} to ${snapshot_dir}"

  echo '{"items":[]}' > "${snapshot_dir}/clusteroperators.json"
  if [[ "${operators_verified}" == true ]]; then
    jq "${SNAPSHOT_CONDITION_HELPERS}"'{
      items: [.items[] | {
        name: .metadata.name,
        available: all_true_status("Available"),
        degraded: any_true_status("Degraded"),
        progressing: any_true_status("Progressing"),
        # One row per operator, and only from a payload shaped the way the
        # API defines it: .status.versions is an array of objects whose name
        # and version are both required strings. Every entry is checked, not
        # just the matching one, for the same reason the condition shape
        # check above covers conditions this step never reads: a payload
        # breaking the published contract is not one to vouch for. The API
        # enforces no uniqueness on that array (unlike .status.conditions,
        # which is a list-map keyed by type), yet the contract names a single
        # "operator" entry -- so more than one, whatever the values, is a
        # payload this step will not vouch for. Anything malformed raises an
        # error here and takes the projection-failure path below, which marks
        # the operators unverified instead of publishing a guess. Having no
        # entry named "operator" is legitimate, and projects an empty string.
        version: (.status.versions as $versions
                  | if $versions == null then ""
                    elif ($versions | type) != "array"
                      then error("status.versions is not an array")
                    elif ($versions | all(type == "object") | not)
                      then error("status.versions has a non-object entry")
                    elif ($versions | all((.name | type) == "string"
                                          and (.version | type) == "string") | not)
                      then error("status.versions has an entry without a string name and version")
                    else ([$versions[] | select(.name == "operator")]
                          | if length == 0 then ""
                            elif length > 1
                              then error("multiple operator version entries")
                            else .[0].version
                            end)
                    end)
      }]
    }' "${co_snapshot_json}" > "${snapshot_dir}/clusteroperators.json" || {
      # A projection that cannot be computed is as unverified as a read that
      # failed; it must not leave an empty list looking like a clean cluster.
      # This is deliberately strict: a payload whose non-health fields cannot
      # be projected is not a payload this step is willing to vouch for.
      echo '{"items":[]}' > "${snapshot_dir}/clusteroperators.json"
      operators_verified=false
    }
  fi

  echo '{"items":[]}' > "${snapshot_dir}/nodes.json"
  if [[ "${nodes_verified}" == true ]]; then
    jq "${SNAPSHOT_CONDITION_HELPERS}"'{
      items: [.items[] | {
        name: .metadata.name,
        ready: all_true_status("Ready"),
        schedulable: (if (.spec | type) == "null" then true
                      elif (.spec | type) != "object" then error("spec is not an object")
                      elif .spec.unschedulable == null then true
                      elif (.spec.unschedulable | type) == "boolean" then (.spec.unschedulable | not)
                      else error("spec.unschedulable is not a boolean")
                      end),
        roles: (if .metadata.labels == null then []
                elif (.metadata.labels | type) == "object"
                then ([.metadata.labels | keys[] | select(startswith("node-role.kubernetes.io/"))] | map(sub("node-role.kubernetes.io/"; "")))
                else error("metadata.labels is not an object")
                end)
      }]
    }' "${nodes_snapshot_json}" > "${snapshot_dir}/nodes.json" || {
      echo '{"items":[]}' > "${snapshot_dir}/nodes.json"
      nodes_verified=false
      node_count=0
    }
  fi

  # Health lists come last, so a projection failure above has already marked the
  # resource unverified and no names are published for it.
  local degraded_raw="" unavailable_raw="" notready_raw=""
  # These jq programs are total over payloads get_resource_json accepts, but a
  # jq that fails for any other reason must mark the resource unverified rather
  # than leave an empty list beside a verified flag.
  if [[ "${operators_verified}" == true ]]; then
    degraded_raw="$(jq -r '.items[]? | select(any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | .metadata.name' "${co_snapshot_json}")" || operators_verified=false
    unavailable_raw="$(jq -r --arg condition Available "${UNHEALTHY_BY_CONDITION}" "${co_snapshot_json}")" || operators_verified=false
  fi
  if [[ "${nodes_verified}" == true ]]; then
    notready_raw="$(jq -r --arg condition Ready "${UNHEALTHY_BY_CONDITION}" "${nodes_snapshot_json}")" || nodes_verified=false
  fi
  # An unverified resource publishes no names, no counts and no projection:
  # leaving the projection in place would let clusteroperator_count and
  # ready_node_count be computed from data the health lists just disowned.
  # The replacement writes are checked explicitly because both call sites
  # invoke this function in a context that suppresses errexit, so an
  # unwritable projection would otherwise survive unnoticed.
  if [[ "${operators_verified}" != true ]]; then
    degraded_raw=""
    unavailable_raw=""
    if ! echo '{"items":[]}' > "${snapshot_dir}/clusteroperators.json"; then
      error "${cluster_role}: could not clear the ClusterOperator projection; refusing to publish metadata"
      # Nothing disowned may stay readable: a consumer reading a projection
      # directly would otherwise see data this capture just repudiated.
      rm -f "${snapshot_dir}/metadata.json" "${snapshot_dir}/clusteroperators.json"
      [[ "${nodes_verified}" == true ]] || rm -f "${snapshot_dir}/nodes.json"
      return 1
    fi
  fi
  if [[ "${nodes_verified}" != true ]]; then
    notready_raw=""
    node_count=0
    if ! echo '{"items":[]}' > "${snapshot_dir}/nodes.json"; then
      error "${cluster_role}: could not clear the node projection; refusing to publish metadata"
      rm -f "${snapshot_dir}/metadata.json" "${snapshot_dir}/nodes.json"
      [[ "${operators_verified}" == true ]] || rm -f "${snapshot_dir}/clusteroperators.json"
      return 1
    fi
  fi

  # The snapshot is a second look at the cluster, taken after the report. If it
  # captures a degraded or unavailable operator or a NotReady node, the cluster
  # is unhealthy now, whatever the earlier report concluded, so the artifact
  # must not carry a PASSED status beside a nonempty unhealthy list. The lists
  # the health predicate already produced are the evidence; no extra read.
  local captured_unhealthy=false
  if [[ -n "${degraded_raw}${unavailable_raw}${notready_raw}" ]]; then
    captured_unhealthy=true
  fi

  # An informational capture -- the management cluster -- reports what it saw
  # and never claims a verdict on the cluster under test. It is never
  # downgraded, and an unhealthy management cluster is not a failure here: the
  # hosted cluster's PASS/FAIL must not depend on it.
  local informational=false
  if [[ "${overall_status}" == "INFO" ]]; then
    informational=true
  fi

  # A snapshot that could not verify health, or that verified it as unhealthy,
  # must not publish a PASSED status. The hosted/primary call site turns the
  # non-zero return below into a report-level failure.
  local snapshot_status="${overall_status}"
  if [[ "${operators_verified}" != true || "${nodes_verified}" != true || "${captured_unhealthy}" == true ]]; then
    if [[ "${snapshot_status}" == "PASSED" ]]; then
      snapshot_status="FAILED"
    fi
  fi

  # Written beside the destination and renamed into place, so a failed write
  # can never publish a truncated metadata.json that a consumer would read as
  # complete. The temp lives in the snapshot directory rather than the scratch
  # directory on purpose: across filesystems `mv` degrades to a non-atomic
  # copy, which can leave exactly the partial file this avoids. It holds the
  # same sanitized fields as the final artifact, so it carries nothing the
  # snapshot directory does not already publish, and it is removed either way.
  local metadata_json="${snapshot_dir}/metadata.json"
  local metadata_tmp="${snapshot_dir}/.metadata.json.tmp"
  if ! jq -n \
    --arg topology "${topology}" \
    --arg cluster_role "${cluster_role}" \
    --arg openshift_version "${snapshot_openshift_version}" \
    --arg channel_group "${CHANNEL_GROUP:-}" \
    --arg cluster_id "${snapshot_cluster_id}" \
    --arg hosted_cluster_id "${CLUSTER_ID}" \
    --arg cluster_version "${cluster_version}" \
    --arg management_cluster_name "${mgmt_name}" \
    --arg management_cluster_id "${mgmt_id}" \
    --arg job_name "${JOB_NAME:-}" \
    --arg build_id "${BUILD_ID:-}" \
    --arg captured_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg overall_status "${snapshot_status}" \
    --argjson clusteroperators_verified "${operators_verified}" \
    --argjson nodes_verified "${nodes_verified}" \
    --argjson node_count "${node_count}" \
    --arg degraded_raw "${degraded_raw}" \
    --arg unavailable_raw "${unavailable_raw}" \
    --arg notready_raw "${notready_raw}" \
    --slurpfile operators "${snapshot_dir}/clusteroperators.json" \
    --slurpfile nodes "${snapshot_dir}/nodes.json" \
    '{
      topology: $topology,
      cluster_role: $cluster_role,
      openshift_version: $openshift_version,
      channel_group: $channel_group,
      cluster_id: $cluster_id,
      hosted_cluster_id: $hosted_cluster_id,
      cluster_version: $cluster_version,
      management_cluster_name: $management_cluster_name,
      management_cluster_id: $management_cluster_id,
      job_name: $job_name,
      build_id: $build_id,
      captured_at: $captured_at,
      overall_status: $overall_status,
      clusteroperators_verified: $clusteroperators_verified,
      nodes_verified: $nodes_verified,
      node_count: $node_count,
      degraded_operators: ($degraded_raw | split("\n") | map(select(length > 0))),
      unavailable_operators: ($unavailable_raw | split("\n") | map(select(length > 0))),
      notready_nodes: ($notready_raw | split("\n") | map(select(length > 0))),
      clusteroperator_count: (($operators[0].items // []) | length),
      ready_node_count: (($nodes[0].items // []) | map(select(.ready=="True")) | length)
    }' > "${metadata_tmp}"; then
    error "${cluster_role}: failed to write metadata.json"
    rm -f "${metadata_tmp}" "${metadata_json}"
    return 1
  fi
  # -T so a directory already at that path is a publication failure instead of
  # a successful move into it, which would leave no metadata.json to read.
  if ! mv -T -- "${metadata_tmp}" "${metadata_json}"; then
    # Also drop the destination: a partially copied file, or one left by an
    # earlier writer, must not be read as this run's snapshot.
    error "${cluster_role}: failed to publish metadata.json"
    rm -f "${metadata_tmp}" "${metadata_json}"
    return 1
  fi

  if [[ "${operators_verified}" != true || "${nodes_verified}" != true ]]; then
    error "${cluster_role}: snapshot could not verify ClusterOperator/node health (operators_verified=${operators_verified} nodes_verified=${nodes_verified})"
    return 1
  fi

  if [[ "${captured_unhealthy}" == true && "${informational}" != true ]]; then
    error "${cluster_role}: snapshot captured unhealthy ClusterOperators or nodes after the report"
    return 1
  fi

  log "Cluster install snapshot JSON written (${cluster_role}): ${snapshot_dir}/metadata.json"
}

HOSTED_OVERALL="$( [[ ${VALIDATION_FAILED} -eq 1 ]] && echo FAILED || echo PASSED )"
primary_role="${topology}"
if [[ "${topology}" == "hcp" ]]; then
  primary_role="hosted"
fi
if ! write_install_snapshot "${primary_role}" "${ARTIFACT_DIR}" "${HOSTED_OVERALL}"; then
  # The report queries may well have succeeded; a snapshot-only failure still
  # means the published snapshot cannot vouch for the cluster. When the report
  # had already failed, the snapshot is confirming what the report said, so
  # only the log records it: a second FAILED line would read as a new problem.
  error "Cluster snapshot did not confirm a healthy cluster"
  if [[ ${VALIDATION_FAILED} -ne 1 ]]; then
    echo "Status: FAILED (snapshot did not confirm a healthy cluster)" >> "${INSTALL_REPORT}"
  fi
  VALIDATION_FAILED=1
fi

# Management-cluster capture is HCP-only. Classic and OSD GCP are
# single-cluster topologies and must keep writing only root ARTIFACT_DIR files. PASS/FAIL stays on this cluster.
if [[ "${topology}" == "hcp" ]]; then
  HOSTED_KUBECONFIG="${KUBECONFIG}"
  if resolve_management_kubeconfig; then
    if oc whoami --request-timeout=30s &>/dev/null; then
      collect_hcp_control_plane_diagnostics
      write_install_snapshot "management" "${ARTIFACT_DIR}/management" "INFO" || \
        log "WARNING: management-cluster install snapshot failed; hosted snapshot is still available"
    else
      log "WARNING: management kubeconfig is not usable; skipping management install snapshot"
    fi
  else
    log "WARNING: management kubeconfig not available; hosted/guest snapshot only"
  fi
  export KUBECONFIG="${HOSTED_KUBECONFIG}"
fi

###########################################
# Generate final validation report
###########################################
echo "" >> "${INSTALL_REPORT}"
echo "========================================" >> "${INSTALL_REPORT}"
echo "Validation Summary" >> "${INSTALL_REPORT}"
echo "========================================" >> "${INSTALL_REPORT}"

if [[ ${VALIDATION_FAILED} -eq 1 ]]; then
  echo "Overall Status: FAILED" >> "${INSTALL_REPORT}"
  error "Gap-analysis validation FAILED. See ${INSTALL_REPORT} for details."
else
  echo "Overall Status: PASSED" >> "${INSTALL_REPORT}"
  success "Gap-analysis validation PASSED."
fi

echo "Report generated at: ${INSTALL_REPORT}"
echo "Artifacts directory: ${ARTIFACT_DIR}"

log "Gap-analysis validation complete."
exit ${VALIDATION_FAILED}
