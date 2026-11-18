#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Pin policy-collection to immutable SHA (INTEROP-9691)
# Verified via: git ls-remote https://github.com/stolostron/policy-collection.git HEAD => 6d80aff5dda558516fced50640d028bce8dd2341
# and byte-check: policygenerator/policy-sets/stable/openshift-plus/ exists at this SHA
if [[ -z "${POLICY_COLLECTION_REF:-}" ]]; then
  echo "ERROR: POLICY_COLLECTION_REF is not set" >&2
  exit 1
fi
if [[ ! "${POLICY_COLLECTION_REF}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: POLICY_COLLECTION_REF must be a 40-char SHA, got '${POLICY_COLLECTION_REF}'" >&2
  exit 1
fi
# Single-channel assertion guard: fail closed if more than one ref is resolved
typeset -i _pc_ref_count
_pc_ref_count=$(git ls-remote https://github.com/stolostron/policy-collection.git "${POLICY_COLLECTION_REF}" 2>/dev/null | wc -l)
if (( _pc_ref_count > 1 )); then
  echo "ERROR: POLICY_COLLECTION_REF '${POLICY_COLLECTION_REF}' matches ${_pc_ref_count} refs (expected 0 or 1 for SHA); failing closed" >&2
  exit 1
fi

cd /tmp/
git clone https://github.com/stolostron/policy-collection.git
cd policy-collection
git fetch --depth 1 origin "${POLICY_COLLECTION_REF}"
git checkout "${POLICY_COLLECTION_REF}"
# Verify checkout matches pinned SHA
typeset _pc_checked_sha
_pc_checked_sha=$(git rev-parse HEAD)
if [[ "${_pc_checked_sha}" != "${POLICY_COLLECTION_REF}" ]]; then
  echo "ERROR: checked out SHA '${_pc_checked_sha}' != expected '${POLICY_COLLECTION_REF}'" >&2
  exit 1
fi
# Byte-check: ensure expected policy set path exists at this SHA
if [[ ! -f "policygenerator/policy-sets/stable/openshift-plus/policyGenerator.yaml" ]]; then
  echo "ERROR: policygenerator/policy-sets/stable/openshift-plus/ not found at ${POLICY_COLLECTION_REF}" >&2
  exit 1
fi
if [[ ! -f "policygenerator/policy-sets/stable/openshift-plus/input-quay/policy-install-quay.yaml" ]]; then
  echo "ERROR: input-quay/policy-install-quay.yaml not found at ${POLICY_COLLECTION_REF}" >&2
  exit 1
fi
if [[ ! -f "policygenerator/policy-sets/stable/openshift-plus/input-odf/policy-odf.yaml" ]]; then
  echo "ERROR: input-odf/policy-odf.yaml not found at ${POLICY_COLLECTION_REF}" >&2
  exit 1
fi

cd deploy/

# If QUAY_OPERATOR_CHANNEL is set, patch the Quay operator subscription to pin the channel
if [[ -n "${QUAY_OPERATOR_CHANNEL}" ]]; then
  if [[ ! "${QUAY_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid QUAY_OPERATOR_CHANNEL: ${QUAY_OPERATOR_CHANNEL}" >&2
    exit 1
  fi
  typeset quayPolicyFile="../policygenerator/policy-sets/stable/openshift-plus/input-quay/policy-install-quay.yaml"
  sed -i "/^    name: quay-operator$/a\\    channel: ${QUAY_OPERATOR_CHANNEL}" "${quayPolicyFile}"
  grep -A5 'name: quay-operator' "${quayPolicyFile}"
fi

# If ODF_OPERATOR_CHANNEL is set, patch the ODF operator subscription to pin the channel
if [[ -n "${ODF_OPERATOR_CHANNEL}" ]]; then
  if [[ ! "${ODF_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid ODF_OPERATOR_CHANNEL: ${ODF_OPERATOR_CHANNEL}" >&2
    exit 1
  fi
  typeset odfPolicyFile="../policygenerator/policy-sets/stable/openshift-plus/input-odf/policy-odf.yaml"
  sed -i "/^    name: odf-operator$/a\\    channel: ${ODF_OPERATOR_CHANNEL}" "${odfPolicyFile}"
  grep -A5 'name: odf-operator' "${odfPolicyFile}"
fi

# Remove the local-cluster exclusion from the clusters placement so
# SecuredCluster policies can target local-cluster.  In OPP single-
# cluster test environments local-cluster is the only managed cluster,
# and the default NotIn rule prevents the SecuredCluster CR from being
# created; causing stackrox-opp-readiness to timeout.
sed -i '/local-cluster.*NotIn/d' \
  ../policygenerator/policy-sets/stable/openshift-plus/input/clusters-placement.yaml

echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -b "${POLICY_COLLECTION_REF}" -a openshift-plus

# openshift-plus generates ~25 policies; require 4+ before oc wait to avoid
# racing the GitOps Subscription propagation (stolostron/policy-collection#174)
typeset -i expectedMinPolicies=4
typeset -i pollDeadline=$((SECONDS + 600))
until (( $(oc get policies -n policies -o json 2>/dev/null | jq '.items | length') >= expectedMinPolicies )); do
  ((SECONDS > pollDeadline)) && {
    printf '%s\n' "Error: fewer than ${expectedMinPolicies} policies after 10 minutes" >&2
    exit 1
  }
  sleep 5
done

# Wait for Quay registry to be ready (checks operator-deployed Quay)
typeset -a quayNamespacesArr=(quay openshift-quay quay-enterprise)
typeset quayFound=false
typeset ns=''
for ns in "${quayNamespacesArr[@]}"; do
  if (($(oc get quayregistry -n "${ns}" -o json 2>/dev/null | jq '.items | length'))); then
    : "Found Quay Operator deployment in namespace ${ns}, waiting for ready condition"
    if ! oc wait quayregistry --all -n "${ns}" \
      --for condition=Available=True \
      --timeout=10m; then
      oc get quayregistry --all -n "${ns}" --ignore-not-found -o yaml
      oc describe quayregistry --all -n "${ns}"
      exit 1
    fi
    quayFound=true
    break
  fi
done
[[ "${quayFound}" == "false" ]] && : "Warning: no QuayRegistry found in namespaces: ${quayNamespacesArr[*]}"

# ── SKIP_POLICIES handling ──────────────────────────────────────────
# SKIP_POLICIES: comma-separated policy names to exclude from the
# compliance wait.  Empty (default) means wait for ALL policies.
# Non-existent policy names produce a warning, not a failure.
typeset -a skipPoliciesArr=()
if [[ -n "${SKIP_POLICIES:-}" ]]; then
  IFS=',' read -ra skipPoliciesArr <<< "${SKIP_POLICIES}"
  printf '[%s] SKIP_POLICIES set; will skip %d polic(ies):\n' \
    "$(date -u +%FT%TZ)" "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '  - %s\n' "${p}"
  done
fi

# Write the full skip manifest for auditing / artifact collection
{
  printf '# skip-policies manifest; generated %s\n' "$(date -u +%FT%TZ)"
  printf '# SKIP_POLICIES=%s\n' "${SKIP_POLICIES:-}"
  printf '# Total policies to skip: %d\n' "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '%s\n' "${p}"
  done
} > "${ARTIFACT_DIR}/skip-policies.txt"

if (( ${#skipPoliciesArr[@]} > 0 )); then
  # Validate that skip-listed policies actually exist in the cluster
  typeset allPolicies=""
  allPolicies="$(oc get policies -n policies -o name 2>/dev/null)" || true
  for p in "${skipPoliciesArr[@]}"; do
    if ! echo "${allPolicies}" | grep -q "/${p}$"; then
      printf '[%s] WARNING: policy "%s" from SKIP_POLICIES not found in cluster (ignoring)\n' \
        "$(date -u +%FT%TZ)" "${p}"
    fi
  done

  # Build a regex to filter out skipped policies
  typeset skipRegex=""
  skipRegex="$(IFS='|'; echo "${skipPoliciesArr[*]}")"
  # Fetch the full policy list first; fail hard if oc cannot reach the cluster
  typeset policyList=""
  policyList="$(oc get policies -n policies -o name)" || {
    printf '[%s] ERROR: failed to list policies in namespace "policies"\n' \
      "$(date -u +%FT%TZ)" >&2
    exit 1
  }
  # Filter out skipped policies (grep no-match is tolerated via || true)
  typeset applyPolicies=""
  applyPolicies="$(printf '%s\n' "${policyList}" | grep -Ev "/(${skipRegex})$")" || true

  if [[ -n "${applyPolicies}" ]]; then
    printf '[%s] Waiting for %d non-skipped polic(ies) to become Compliant…\n' \
      "$(date -u +%FT%TZ)" "$(echo "${applyPolicies}" | wc -l)"
    if ! echo "${applyPolicies}" |
      xargs oc wait -n policies \
        --for jsonpath='{.status.compliant}'=Compliant \
        --timeout=40m; then
      : "Non-skipped policies failed to become compliant:"
      oc get policies -n policies --ignore-not-found | grep -Ev "/(${skipRegex})$"
      oc get policies -n policies --ignore-not-found -o yaml
      oc describe policies -n policies
      exit 1
    fi
  else
    printf '[%s] All policies are in the skip list; no policies to wait for\n' \
      "$(date -u +%FT%TZ)"
  fi
else
  printf '[%s] No policies to skip; waiting for ALL policies to become Compliant…\n' \
    "$(date -u +%FT%TZ)"
  if ! oc wait policies --all -n policies \
    --for jsonpath='{.status.compliant}'=Compliant \
    --timeout=40m; then
    : "Policies failed to become compliant:"
    oc get policies -n policies --ignore-not-found
    oc get policies -n policies --ignore-not-found -o yaml
    oc describe policies -n policies
    exit 1
  fi
fi

true
