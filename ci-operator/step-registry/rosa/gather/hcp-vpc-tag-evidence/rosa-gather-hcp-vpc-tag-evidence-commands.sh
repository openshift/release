#!/bin/bash

# Best-effort evidence collector for ROSA HCP conformance runs.
#
# Conformance cases that assert on the guest cluster's VPC tags expect a
# "kubernetes.io/cluster/<guest Infrastructure name>" tag with the value
# "owned", while CI provisioning tags the job-provisioned VPC with
# "kubernetes.io/cluster/<CI infrastructure identifier>" = "shared" using the
# identifier handed off in ${SHARED_DIR}/infra_id. When those two names are not
# the same string the expected "owned" tag is not the tag CI wrote, and the
# runtime tag state is gone by the time the job artifacts are inspected because
# the VPC is deleted during teardown.
#
# This step records that state while the VPC still exists. It is purely
# observational:
#   * It never fails the job. Every failure path degrades to "unavailable" and
#     the step always exits 0, so the conformance verdict and every later
#     teardown/cleanup step are unaffected.
#   * It never mutates cluster or cloud state. It performs at most one
#     read-only guest API read and at most one read-only describe of the single
#     VPC whose id the job already recorded in ${SHARED_DIR}/vpc_id. There is no
#     discovery, listing or fallback lookup of any other resource, and it adds
#     no new credential or mount: it reads the same cluster-profile credential
#     the job already uses for this VPC.
#   * It does need the ec2:DescribeTags action. The job's existing
#     ec2:CreateTags use on this VPC does not by itself grant that action, so
#     if the cluster-profile policy omits it the call is simply denied, both
#     tag states stay "unavailable", and nothing else changes.
#
# Only fixed states from a closed set are emitted. Identifiers, tag keys, tag
# values, command stderr and raw API output never reach the log or the
# artifact; "unavailable" (could not be determined) is reported distinctly from
# "absent" (determined to be missing).

set -o nounset
set -o pipefail

# Bound every external call so a hung API cannot delay teardown. KILL_AFTER
# escalates to SIGKILL so the bound holds even if a client ignores SIGTERM.
readonly KILL_AFTER=10
readonly OC_TIMEOUT=60
readonly OC_REQUEST_TIMEOUT=30s
readonly AWS_TIMEOUT=60
readonly AWS_CONNECT_TIMEOUT=10
readonly AWS_READ_TIMEOUT=30
export AWS_MAX_ATTEMPTS=2
export AWS_RETRY_MODE=standard

readonly TAG_PREFIX="kubernetes.io/cluster/"
readonly GUEST_TAG_VALUE="owned"
readonly CI_TAG_VALUE="shared"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

# Final redaction guard: only members of the closed state set can ever be
# printed or written, so no identifier or API text can escape through a state
# variable even if an upstream step behaves unexpectedly.
sanitize_state() {
  case "${1:-}" in
    available | unavailable | match | differ | present | absent) printf '%s' "${1}" ;;
    *) printf '%s' "unavailable" ;;
  esac
}

# Echoes nothing when the file is missing, empty or unreadable.
read_handoff() {
  local path="${1}"
  [[ -s "${path}" ]] || return 0
  head -n 1 "${path}" 2>/dev/null | tr -d '[:space:]'
}

# Reject anything that is not a plausible identifier before it is used to build
# an AWS filter, so malformed handoff content is reported as unavailable rather
# than being sent to the API.
valid_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]{0,62}$ ]]
}

valid_vpc_id() {
  [[ "${1:-}" =~ ^vpc-[0-9a-f]{8,17}$ ]]
}

shared_dir="${SHARED_DIR:-}"

# --- CI infrastructure identifier handoff -----------------------------------
ci_infra_id="$(read_handoff "${shared_dir}/infra_id")"
valid_name "${ci_infra_id}" || ci_infra_id=""
ci_infra_id_state="unavailable"
[[ -n "${ci_infra_id}" ]] && ci_infra_id_state="available"

# --- Guest cluster Infrastructure name --------------------------------------
guest_infra_name=""
guest_kubeconfig="${shared_dir}/kubeconfig"
if [[ -s "${guest_kubeconfig}" ]]; then
  guest_infra_name="$(timeout -k "${KILL_AFTER}" "${OC_TIMEOUT}" oc \
    --kubeconfig="${guest_kubeconfig}" \
    --request-timeout="${OC_REQUEST_TIMEOUT}" \
    get infrastructure cluster \
    -o jsonpath='{.status.infrastructureName}' 2>/dev/null | tr -d '[:space:]')" ||
    guest_infra_name=""
fi
valid_name "${guest_infra_name}" || guest_infra_name=""
guest_infra_name_state="unavailable"
[[ -n "${guest_infra_name}" ]] && guest_infra_name_state="available"

# --- Equality of the two names ----------------------------------------------
infra_name_match="unavailable"
if [[ -n "${guest_infra_name}" && -n "${ci_infra_id}" ]]; then
  if [[ "${guest_infra_name}" == "${ci_infra_id}" ]]; then
    infra_name_match="match"
  else
    infra_name_match="differ"
  fi
fi

# --- Tags on the known job-provisioned VPC ----------------------------------
vpc_id="$(read_handoff "${shared_dir}/vpc_id")"
valid_vpc_id "${vpc_id}" || vpc_id=""
vpc_id_state="unavailable"
[[ -n "${vpc_id}" ]] && vpc_id_state="available"

guest_owned_tag="unavailable"
ci_shared_tag="unavailable"

guest_tag_key=""
ci_tag_key=""
[[ -n "${guest_infra_name}" ]] && guest_tag_key="${TAG_PREFIX}${guest_infra_name}"
[[ -n "${ci_infra_id}" ]] && ci_tag_key="${TAG_PREFIX}${ci_infra_id}"

tag_key_filter=""
if [[ -n "${guest_tag_key}" && -n "${ci_tag_key}" && "${guest_tag_key}" != "${ci_tag_key}" ]]; then
  tag_key_filter="${guest_tag_key},${ci_tag_key}"
else
  tag_key_filter="${guest_tag_key:-${ci_tag_key}}"
fi

# Accepts the response only if it is exactly one complete JSON document whose
# .Tags is an array of well-formed {Key,Value} string entries.
#
# This gate has to exist separately from the match below: a valid JSON document
# of the wrong shape ({}, {"Tags":null}, {"Tags":"x"}, an entry with no Value)
# makes the match simply find nothing, which is indistinguishable from a real
# miss. Without the gate every one of those shapes would be reported as a tag
# that is genuinely absent.
#
# A response carrying NextToken is truncated: a tag that is not on this page
# has not been shown to be missing, so it is rejected for the same reason. The
# query is scoped to one VPC and at most two keys and runs with --no-paginate,
# so a complete answer always fits one page in practice.
#
# Entries may carry extra fields (ResourceId, ResourceType) and the document
# may carry other top-level fields; only the parts that are relied on are
# constrained, so real responses are not rejected. An empty .Tags array is well
# formed and deliberately accepted, because that is what a VPC carrying neither
# tag actually returns.
response_is_well_formed() {
  [[ -s "${work_dir}/tags.json" ]] || return 1
  # -s collects the whole stream into one array, so its length is the number of
  # JSON documents the response contained.
  jq -e -s '
    length == 1
    and (.[0] | type) == "object"
    and (.[0] | has("NextToken") | not)
    and (.[0].Tags | type) == "array"
    and (.[0].Tags | all(
          (type) == "object"
          and (.Key | type) == "string"
          and (.Value | type) == "string"))' \
    "${work_dir}/tags.json" >/dev/null 2>&1
}

# Reports present/absent for one expected key/value pair without ever emitting
# the key, the value or any part of the API response. Only called once the
# response has been accepted as well-formed, so .Tags is known to be an array
# and non-optional iteration is safe.
#
# Only jq's "predicate was false" status may be reported as "absent". Any other
# failure (jq missing from the image, an unexpected runtime error) means
# nothing was determined and must stay "unavailable", so a lookup that did not
# happen is never recorded as a tag that is missing.
tag_state() {
  local key="${1}" value="${2}" status=0
  jq -e --arg k "${key}" --arg v "${value}" \
    'any(.Tags[]; .Key == $k and .Value == $v)' \
    "${work_dir}/tags.json" >/dev/null 2>&1 || status=$?
  case "${status}" in
    0) printf '%s' "present" ;;
    1) printf '%s' "absent" ;;
    *) printf '%s' "unavailable" ;;
  esac
}

if [[ -n "${vpc_id}" && -n "${tag_key_filter}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR:-}/.awscred"
  region="${REGION:-${LEASED_RESOURCE:-}}"

  # One read-only CLI invocation, scoped to this VPC and to the two expected
  # tag keys. describe-tags is a paginated operation that the CLI would
  # otherwise walk to completion, so --no-paginate holds the invocation to a
  # single scoped request; a truncated answer is then rejected above rather
  # than mistaken for a complete one. The client may still retry that same
  # request up to AWS_MAX_ATTEMPTS times, and the timeout bounds the
  # invocation regardless. stderr is discarded so credential or endpoint
  # detail cannot land in the build log.
  if [[ -n "${region}" ]] && timeout -k "${KILL_AFTER}" "${AWS_TIMEOUT}" aws \
    --region "${region}" \
    --cli-connect-timeout "${AWS_CONNECT_TIMEOUT}" \
    --cli-read-timeout "${AWS_READ_TIMEOUT}" \
    ec2 describe-tags \
    --filters "Name=resource-id,Values=${vpc_id}" "Name=key,Values=${tag_key_filter}" \
    --no-paginate --output json >"${work_dir}/tags.json" 2>/dev/null &&
    response_is_well_formed; then
    [[ -n "${guest_tag_key}" ]] && guest_owned_tag="$(tag_state "${guest_tag_key}" "${GUEST_TAG_VALUE}")"
    [[ -n "${ci_tag_key}" ]] && ci_shared_tag="$(tag_state "${ci_tag_key}" "${CI_TAG_VALUE}")"
  fi
fi

# --- Emit fixed states only --------------------------------------------------
guest_infra_name_state="$(sanitize_state "${guest_infra_name_state}")"
ci_infra_id_state="$(sanitize_state "${ci_infra_id_state}")"
vpc_id_state="$(sanitize_state "${vpc_id_state}")"
infra_name_match="$(sanitize_state "${infra_name_match}")"
guest_owned_tag="$(sanitize_state "${guest_owned_tag}")"
ci_shared_tag="$(sanitize_state "${ci_shared_tag}")"

echo "guest_infrastructure_name: ${guest_infra_name_state}"
echo "ci_infrastructure_identifier: ${ci_infra_id_state}"
echo "vpc_identifier: ${vpc_id_state}"
echo "infrastructure_name_match: ${infra_name_match}"
echo "guest_owned_cluster_tag: ${guest_owned_tag}"
echo "ci_shared_cluster_tag: ${ci_shared_tag}"

if [[ -n "${ARTIFACT_DIR:-}" && -d "${ARTIFACT_DIR}" ]]; then
  cat >"${ARTIFACT_DIR}/hcp-vpc-tag-evidence.json" <<EOF
{
  "schema_version": 1,
  "guest_infrastructure_name": "${guest_infra_name_state}",
  "ci_infrastructure_identifier": "${ci_infra_id_state}",
  "vpc_identifier": "${vpc_id_state}",
  "infrastructure_name_match": "${infra_name_match}",
  "guest_owned_cluster_tag": "${guest_owned_tag}",
  "ci_shared_cluster_tag": "${ci_shared_tag}"
}
EOF
fi

# Always succeed: this step is observational and must not influence the
# conformance verdict or block teardown.
exit 0
