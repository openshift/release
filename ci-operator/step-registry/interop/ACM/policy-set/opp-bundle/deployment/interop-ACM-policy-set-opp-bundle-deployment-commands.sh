#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

cd /tmp/
git clone --depth 1 https://github.com/stolostron/policy-collection.git

cd policy-collection/deploy/

# Channel overrides are applied to the deployed OLM Subscription objects
# in-cluster (see PinSubscriptionChannel below).  Patching the local clone
# has no effect: deploy.sh creates a GitOps Subscription that syncs the
# upstream repository content, so local edits never reach the cluster.
for _channelVar in QUAY_OPERATOR_CHANNEL ODF_OPERATOR_CHANNEL; do
  typeset _channelVal="${!_channelVar:-}"
  if [[ -n "${_channelVal}" ]] && [[ ! "${_channelVal}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid ${_channelVar}: ${_channelVal}" >&2
    exit 1
  fi
done

# Pin an OLM Subscription channel in-cluster.  The subscription objects
# are created by the openshift-plus policies (enforce, musthave
# compliance): an in-cluster merge patch only adds spec.channel, which the
# musthave check does not consider a violation, so the pin persists
# without triggering policy remediation.
PinSubscriptionChannel () {
  typeset subNamespace="${1}" subName="${2}" channel="${3}"
  # Wait through oc wait (Best Practices).  oc wait does not wait for
  # not-yet-created objects (it fails fast on NotFound), so retry it until
  # the subscription appears.
  typeset -i pinWaitMax=600
  SECONDS=0
  while ((SECONDS < pinWaitMax)); do
    oc wait "subscription/${subName}" -n "${subNamespace}" \
      --for jsonpath='{.metadata.name}'="${subName}" \
      --timeout 10s 1>/dev/null && break
    sleep 5
  done
  if ((SECONDS >= pinWaitMax)); then
    printf '%s\n' "Error: subscription ${subNamespace}/${subName} not found after 10 minutes; cannot pin channel ${channel}" >&2
    return 1
  fi
  oc patch subscription "${subName}" -n "${subNamespace}" --type merge \
    -p "{\"spec\":{\"channel\":\"${channel}\"}}"
  printf '[%s] Pinned subscription %s/%s to channel %s\n' \
    "$(date -u +%FT%TZ)" "${subNamespace}" "${subName}" "${channel}"
}

echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus

# openshift-plus generates ~25 policies; require 4+ before oc wait to avoid
# racing the GitOps Subscription propagation (stolostron/policy-collection#174)
typeset -i expectedMinPolicies=4
typeset -i pollDeadline=$((SECONDS + 600))
until (( $(oc get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length') >= expectedMinPolicies )); do
  ((SECONDS > pollDeadline)) && {
    printf '%s\n' "Error: fewer than ${expectedMinPolicies} policies after 10 minutes" >&2
    exit 1
  }
  sleep 5
done

# Apply requested channel overrides to the deployed OLM subscriptions.
[[ -n "${QUAY_OPERATOR_CHANNEL:-}" ]] && \
  PinSubscriptionChannel local-quay quay-operator "${QUAY_OPERATOR_CHANNEL}"
[[ -n "${ODF_OPERATOR_CHANNEL:-}" ]] && \
  PinSubscriptionChannel openshift-storage odf-operator "${ODF_OPERATOR_CHANNEL}"

# Remove the local-cluster exclusion from the clusters placement in-cluster
# so SecuredCluster policies can target local-cluster.  In OPP single-cluster
# test environments local-cluster is the only managed cluster, and the
# default NotIn rule prevents the SecuredCluster CR from being created:
# causing stackrox-opp-readiness to timeout.  Best effort: if the placement
# shape differs or the appsub resync restores the predicate, behaviour falls
# back to the upstream default.
typeset isPlacementFound=false
typeset -i placementWaitMax=300
SECONDS=0
while ((SECONDS < placementWaitMax)); do
  if oc wait "placement/placement-openshift-plus-clusters" -n policies \
    --for jsonpath='{.metadata.name}'=placement-openshift-plus-clusters \
    --timeout 10s 1>/dev/null; then
    isPlacementFound=true
    break
  fi
  sleep 5
done
if [[ "${isPlacementFound}" == true ]]; then
  oc patch placement placement-openshift-plus-clusters -n policies --type json \
    -p '[{"op":"test","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1/key","value":"local-cluster"},{"op":"remove","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1"}]' \
    || printf '%s\n' "Warning: could not remove local-cluster NotIn predicate from placement (continuing with upstream default)" >&2
else
  printf '%s\n' "Warning: placement placement-openshift-plus-clusters not found after 5 minutes; skipping local-cluster predicate removal" >&2
fi

# Wait for Quay registry to be ready (checks operator-deployed Quay)
typeset -a quayNamespacesArr=(quay openshift-quay quay-enterprise local-quay)
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
  printf '[%s] SKIP_POLICIES set: will skip %d polic(ies):\n' \
    "$(date -u +%FT%TZ)" "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '  - %s\n' "${p}"
  done
fi

# Write the full skip manifest for auditing / artifact collection
{
  printf '# skip-policies manifest: generated %s\n' "$(date -u +%FT%TZ)"
  printf '# SKIP_POLICIES=%s\n' "${SKIP_POLICIES:-}"
  printf '# Total policies to skip: %d\n' "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '%s\n' "${p}"
  done
} > "${ARTIFACT_DIR}/skip-policies.txt"

# Filter skipped policies by literal name match.  Policy names are matched
# as fixed strings (not regexes) so a name containing regex metacharacters
# cannot widen the match to unrelated policies.
FilterSkippedPolicies () {
  typeset line='' p='' skip=false
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    skip=false
    for p in "${skipPoliciesArr[@]}"; do
      [[ "${line}" == */"${p}" ]] && { skip=true; break; }
    done
    [[ "${skip}" == false ]] && printf '%s\n' "${line}"
  done
  true
}

if (( ${#skipPoliciesArr[@]} > 0 )); then
  # Validate that skip-listed policies actually exist in the cluster
  # (literal, per-line suffix match on the <resource>[.<group>]/<name> form)
  PolicyExists () {
    typeset policyName="${1}" line=''
    while IFS= read -r line; do
      [[ "${line}" == */"${policyName}" ]] && return 0
    done
    return 1
  }
  typeset allPolicies=""
  allPolicies="$(oc get policies -n policies -o name)" || true
  for p in "${skipPoliciesArr[@]}"; do
    if ! PolicyExists "${p}" <<< "${allPolicies}"; then
      printf '[%s] WARNING: policy "%s" from SKIP_POLICIES not found in cluster (ignoring)\n' \
        "$(date -u +%FT%TZ)" "${p}"
    fi
  done
fi

# Wait for the (non-skipped) policies to become Compliant.  `oc wait --all`
# (and the xargs variant) only considers policies that exist when it
# starts, and the GitOps Subscription propagates the set progressively:
# the first policies can appear and become compliant long before the rest
# of the set is created, so a single wait can succeed on a partial set.
# Re-run the compliance wait whenever new policies appeared during the
# previous pass; succeed only after a pass completes with a stable policy
# count.
typeset -i policyCount=0
typeset -i prevCount=-1
while (( policyCount != prevCount )); do
  prevCount="${policyCount}"

  if (( ${#skipPoliciesArr[@]} > 0 )); then
    # Fetch the full policy list first: fail hard if oc cannot reach the cluster
    typeset policyList=""
    policyList="$(oc get policies -n policies -o name)" || {
      printf '[%s] ERROR: failed to list policies in namespace "policies"\n' \
        "$(date -u +%FT%TZ)" >&2
      exit 1
    }
    typeset -a applyPoliciesArr=()
    mapfile -t applyPoliciesArr < <(printf '%s\n' "${policyList}" | FilterSkippedPolicies)

    if (( ${#applyPoliciesArr[@]} > 0 )); then
      printf '[%s] Waiting for %d non-skipped polic(ies) to become Compliant…\n' \
        "$(date -u +%FT%TZ)" "${#applyPoliciesArr[@]}"
      if ! oc wait -n policies \
        --for jsonpath='{.status.compliant}'=Compliant \
        --timeout=40m "${applyPoliciesArr[@]}"; then
        : "Non-skipped policies failed to become compliant:"
        oc get policies -n policies --ignore-not-found | FilterSkippedPolicies
        oc get policies -n policies --ignore-not-found -o yaml
        oc describe policies -n policies
        exit 1
      fi
    else
      printf '[%s] All policies are in the skip list: no policies to wait for\n' \
        "$(date -u +%FT%TZ)"
    fi
  else
    printf '[%s] No policies to skip: waiting for ALL policies to become Compliant…\n' \
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

  # Count after the pass: if the query fails transiently, treat it as a
  # changed set so the next pass re-runs the wait (and fails properly
  # through the wait's diagnostics if the cluster API is really broken).
  policyCount="$(( $(oc get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length' || echo 0) ))"
  printf '[%s] Compliance pass complete: %d policies in the set\n' \
    "$(date -u +%FT%TZ)" "${policyCount}"
done

true
