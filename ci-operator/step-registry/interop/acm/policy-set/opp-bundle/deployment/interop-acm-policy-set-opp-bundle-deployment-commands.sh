#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Restrictive default permissions: anything this step writes is owner-only.
umask 077

# Hard wall-clock budget for the whole step.  The ref timeout is 2h with a
# 5m grace period; the budget stops short of it so a phase that hits the
# limit can record its failure row and let the EXIT trap write the JUnit
# report, instead of the pod being terminated mid-wait with no report at
# all.
typeset -i stepStartBudget=0
stepStartBudget=$(date +%s)
typeset -i stepDeadline=$(( stepStartBudget + 115 * 60 ))
# Longest single compliance pass (the oc wait timeout below), so a pass is
# only started when a full pass still fits inside the step budget.
typeset -i compliancePassBudget=$(( 40 * 60 ))

# --- JUnit carrier ---------------------------------------------------
# Every assertion this step performs is reported as one JUnit testcase.
# The carrier runs from the EXIT trap, so the report is written on both
# the success and the failure path.  Rows start as skipped and are
# recorded as the script reaches each check: a row that never runs stays
# visible as a skip instead of silently disappearing from the report.
ARTIFACT_DIR="${ARTIFACT_DIR:=/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
# Raw suite name and file name carry the step identity; ExitTrap
# post-processing renames the suite and merges this file into
# junit--interop-acm-policy-set-opp-bundle-deployment.xml.
typeset junitFile="${ARTIFACT_DIR}/junit_interop-acm-policy-set-opp-bundle-deployment.xml"

# Suite naming for the JUnit post-processing library: compose its suite-name
# template from the component-suffixed prefix variable the consuming job sets.
# The step ref declares the prefix with no default on purpose, so a step-local
# value can never pin a prefix the job cannot see. When the prefix is unset
# the raw suite name is kept, so the step still reports, and the gap is called
# out loudly instead of failing the run.
if [[ -n "${LP_QE__CR__TS_NAME__PFX__ACM:-}" ]]; then
    export LP_IO__ET_PPP__NEW_TS_NAME="${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}%s"
else
    echo ">>> WARNING: LP_QE__CR__TS_NAME__PFX__ACM is unset or empty; keeping the raw suite name, which will not route to a component" >&2
    unset LP_IO__ET_PPP__NEW_TS_NAME
fi

typeset -A testStatus=()
typeset -A testDuration=()
typeset -A testFailureMsg=()
typeset -a allTests=(
    "openshift-plus-policy-set-deployed"
    "subscription-channel-pin-local-quay-quay-operator"
    "subscription-channel-pin-openshift-storage-odf-operator"
    "local-cluster-placement-predicate-removed"
    "quay-registry-available"
    "policies-compliant"
)

for t in "${allTests[@]}"; do
    testStatus["${t}"]="skipped"
    testDuration["${t}"]=0
    testFailureMsg["${t}"]="Test did not run"
done

typeset -i suiteStart=0
suiteStart=$(date +%s)

RecordResult () {
    typeset name="${1}"; shift
    typeset status="${1}"; shift
    typeset msg="${1:-}"; shift || true
    typeset dur="${1:-0}"; shift || true
    testStatus["${name}"]="${status}"
    testDuration["${name}"]="${dur}"
    testFailureMsg["${name}"]="${msg}"
    true
}

# shellcheck disable=SC2317,SC2329
GenerateJunit () {
    typeset -i total=${#allTests[@]}
    typeset -i failures=0 skipped=0
    typeset -i elapsed=0
    elapsed=$(( $(date +%s) - suiteStart ))

    for t in "${allTests[@]}"; do
        [[ "${testStatus[${t}]}" == "failed" ]] && failures=$((failures + 1))
        [[ "${testStatus[${t}]}" == "skipped" ]] && skipped=$((skipped + 1))
    done

    cat > "${junitFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="interop-acm-policy-set-opp-bundle-deployment" tests="${total}" failures="${failures}" errors="0" skipped="${skipped}" time="${elapsed}">
EOF

    for t in "${allTests[@]}"; do
        typeset escapedName=''
        escapedName="$(printf '%s' "${t}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"
        typeset escapedMsg=''
        escapedMsg="$(printf '%s' "${testFailureMsg[${t}]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"

        if [[ "${testStatus[${t}]}" == "failed" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-acm-policy-set-opp-bundle-deployment\" time=\"${testDuration[${t}]}\"><failure message=\"${escapedMsg}\">${escapedMsg}</failure></testcase>" >> "${junitFile}"
        elif [[ "${testStatus[${t}]}" == "skipped" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-acm-policy-set-opp-bundle-deployment\" time=\"${testDuration[${t}]}\"><skipped message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        else
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-acm-policy-set-opp-bundle-deployment\" time=\"${testDuration[${t}]}\"/>" >> "${junitFile}"
        fi
    done

    cat >> "${junitFile}" <<'EOF'
  </testsuite>
</testsuites>
EOF
    cat "${junitFile}"
    true
}

# shellcheck disable=SC2317
_propagate_junit () {
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; || true
}

# Load ExitTrap library for JUnit XML post-processing at script level
# (must be loaded before trap can fire to avoid secondary errors).
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
)"

# Post-process the JUnit XML for Component Readiness routing.  Guarded on
# purpose: this runs from the EXIT trap, and an unloaded helper (download
# failure) or a post-processing failure must not overwrite the script's
# exit status (the unguarded call fails the trap with 127 and turns a
# passing run into a failure).  The merged file name is passed explicitly:
# the library default (jUnit.xml) is not picked up by the prow JUnit viewer
# (lowercase junit prefix required) and collides with other steps in
# shared storage.
PostProcessJunit () {
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        ExitTrap--PostProcessPrep junit--interop-acm-policy-set-opp-bundle-deployment.xml ||
            echo "WARNING: junit post-processing failed" >&2
    else
        echo "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
    true
}

trap '_opp_test_status=$?; set +e; GenerateJunit; _propagate_junit; PostProcessJunit; exit ${_opp_test_status}' EXIT

cd /tmp/
# A re-run in the same pod leaves the clone behind and a shallow clone
# refuses to target a non-empty directory, so clear it first.
rm -rf /tmp/policy-collection
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
  # Best Practices: wait with `oc wait --for=create` (plain condition
  # waits fail fast on NotFound, so the object must be awaited for
  # creation first); then pin the channel on the existing subscription.
  if ! oc wait "subscription/${subName}" -n "${subNamespace}" \
      --for=create --timeout=600s 1>/dev/null; then
    printf '%s\n' "Error: subscription ${subNamespace}/${subName} not found after 10 minutes; cannot pin channel ${channel}" >&2
    return 1
  fi
  if ! oc patch subscription "${subName}" -n "${subNamespace}" --type merge \
    -p "{\"spec\":{\"channel\":\"${channel}\"}}"; then
    printf '%s\n' "Error: failed to patch subscription ${subNamespace}/${subName} to channel ${channel}" >&2
    return 1
  fi
  printf '[%s] Pinned subscription %s/%s to channel %s\n' \
    "$(date -u +%FT%TZ)" "${subNamespace}" "${subName}" "${channel}"
}

echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus

# openshift-plus generates ~25 policies; require 4+ before oc wait to avoid
# racing the GitOps Subscription propagation (stolostron/policy-collection#174)
typeset -i expectedMinPolicies=4
typeset -i pollDeadline=$((SECONDS + 600))
typeset -i policyGateStart=0
policyGateStart=$(date +%s)
until (( $(oc get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length') >= expectedMinPolicies )); do
  ((SECONDS > pollDeadline)) && {
    printf '%s\n' "Error: fewer than ${expectedMinPolicies} policies after 10 minutes" >&2
    RecordResult "openshift-plus-policy-set-deployed" "failed" "Fewer than ${expectedMinPolicies} policies in namespace policies after 10 minutes" "$(( $(date +%s) - policyGateStart ))"
    exit 1
  }
  sleep 5
done
RecordResult "openshift-plus-policy-set-deployed" "passed" "" "$(( $(date +%s) - policyGateStart ))"

# Apply requested channel overrides to the deployed OLM subscriptions.
if [[ -n "${QUAY_OPERATOR_CHANNEL:-}" ]]; then
  typeset -i quayPinStart=0
  quayPinStart=$(date +%s)
  if PinSubscriptionChannel local-quay quay-operator "${QUAY_OPERATOR_CHANNEL}"; then
    RecordResult "subscription-channel-pin-local-quay-quay-operator" "passed" "" "$(( $(date +%s) - quayPinStart ))"
  else
    RecordResult "subscription-channel-pin-local-quay-quay-operator" "failed" "Could not pin subscription local-quay/quay-operator to channel ${QUAY_OPERATOR_CHANNEL}" "$(( $(date +%s) - quayPinStart ))"
    exit 1
  fi
else
  RecordResult "subscription-channel-pin-local-quay-quay-operator" "skipped" "QUAY_OPERATOR_CHANNEL not set"
fi
if [[ -n "${ODF_OPERATOR_CHANNEL:-}" ]]; then
  typeset -i odfPinStart=0
  odfPinStart=$(date +%s)
  if PinSubscriptionChannel openshift-storage odf-operator "${ODF_OPERATOR_CHANNEL}"; then
    RecordResult "subscription-channel-pin-openshift-storage-odf-operator" "passed" "" "$(( $(date +%s) - odfPinStart ))"
  else
    RecordResult "subscription-channel-pin-openshift-storage-odf-operator" "failed" "Could not pin subscription openshift-storage/odf-operator to channel ${ODF_OPERATOR_CHANNEL}" "$(( $(date +%s) - odfPinStart ))"
    exit 1
  fi
else
  RecordResult "subscription-channel-pin-openshift-storage-odf-operator" "skipped" "ODF_OPERATOR_CHANNEL not set"
fi

# Remove the local-cluster exclusion from the clusters placement in-cluster
# so SecuredCluster policies can target local-cluster.  In OPP single-cluster
# test environments local-cluster is the only managed cluster, and the
# default NotIn rule prevents the SecuredCluster CR from being created:
# causing stackrox-opp-readiness to timeout.  Best effort: if the placement
# shape differs or the appsub resync restores the predicate, behaviour falls
# back to the upstream default.
# Best Practices: wait with `oc wait --for=create` instead of a polling
# loop (plain condition waits fail fast on NotFound).
typeset -i placementStart=0
placementStart=$(date +%s)
if oc wait "placement/placement-openshift-plus-clusters" -n policies \
    --for=create --timeout=300s 1>/dev/null; then
  if oc patch placement placement-openshift-plus-clusters -n policies --type json \
    -p '[{"op":"test","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1/key","value":"local-cluster"},{"op":"remove","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1"}]'; then
    RecordResult "local-cluster-placement-predicate-removed" "passed" "" "$(( $(date +%s) - placementStart ))"
  else
    printf '%s\n' "Warning: could not remove local-cluster NotIn predicate from placement (continuing with upstream default)" >&2
    RecordResult "local-cluster-placement-predicate-removed" "skipped" "Placement patch did not apply; upstream default predicate retained" "$(( $(date +%s) - placementStart ))"
  fi
else
  printf '%s\n' "Warning: placement placement-openshift-plus-clusters not found after 5 minutes; skipping local-cluster predicate removal" >&2
  RecordResult "local-cluster-placement-predicate-removed" "skipped" "Placement placement-openshift-plus-clusters not found after 5 minutes" "$(( $(date +%s) - placementStart ))"
fi

# Wait for Quay registry to be ready (checks operator-deployed Quay)
typeset -a quayNamespacesArr=(quay openshift-quay quay-enterprise local-quay)
typeset quayFound=false
typeset -i quayStart=0
quayStart=$(date +%s)
typeset ns=''
for ns in "${quayNamespacesArr[@]}"; do
  # Branch on the query's exit status: an API or RBAC failure must not read
  # as "no QuayRegistry in this namespace".  Only the CRD-absent and
  # empty-list answers are expected, and those stay quiet.
  typeset quayJson="" quayQueryErr=""
  typeset -i quayQueryRc=0
  quayJson="$(oc get quayregistry -n "${ns}" -o json 2>&1)" || quayQueryRc=$?
  if (( quayQueryRc != 0 )); then
    quayQueryErr="${quayJson}"
    if [[ "${quayQueryErr}" == *"doesn't have a resource type"* || "${quayQueryErr}" == *"No resources found"* ]]; then
      : "No QuayRegistry API or objects in namespace ${ns}"
    else
      printf '%s\n' "Warning: could not query QuayRegistry in namespace ${ns} (rc=${quayQueryRc}): ${quayQueryErr}" >&2
    fi
    continue
  fi
  typeset -i quayItemCount=0
  if ! quayItemCount="$(printf '%s' "${quayJson}" | jq '.items | length')"; then
    printf '%s\n' "Warning: could not count QuayRegistry objects in namespace ${ns}; skipping it" >&2
    continue
  fi
  if (( quayItemCount > 0 )); then
    : "Found Quay Operator deployment in namespace ${ns}, waiting for ready condition"
    if ! oc wait quayregistry --all -n "${ns}" \
      --for condition=Available=True \
      --timeout=10m; then
      RecordResult "quay-registry-available" "failed" "QuayRegistry in namespace ${ns} did not become Available within 10 minutes" "$(( $(date +%s) - quayStart ))"
      oc get quayregistry --all -n "${ns}" --ignore-not-found -o yaml
      oc describe quayregistry --all -n "${ns}"
      exit 1
    fi
    RecordResult "quay-registry-available" "passed" "" "$(( $(date +%s) - quayStart ))"
    quayFound=true
    break
  fi
done
if [[ "${quayFound}" == "false" ]]; then
  printf '%s\n' "Warning: no QuayRegistry found in namespaces: ${quayNamespacesArr[*]}" >&2
  RecordResult "quay-registry-available" "skipped" "No QuayRegistry found in namespaces: ${quayNamespacesArr[*]}" "$(( $(date +%s) - quayStart ))"
fi

# ── SKIP_POLICIES handling ──────────────────────────────────────────
# SKIP_POLICIES: comma-separated policy names to exclude from the
# compliance wait.  Empty (default) means wait for ALL policies.
# Non-existent policy names produce a warning, not a failure.
typeset -a skipPoliciesArr=()
if [[ -n "${SKIP_POLICIES:-}" ]]; then
  IFS=',' read -ra _skipRawArr <<< "${SKIP_POLICIES}"
  for _skipEntry in "${_skipRawArr[@]}"; do
    # Trim surrounding whitespace: an untrimmed entry ("a, b" yields " b")
    # would never match a policy name and would silently skip nothing.
    _skipEntry="${_skipEntry#"${_skipEntry%%[![:space:]]*}"}"
    _skipEntry="${_skipEntry%"${_skipEntry##*[![:space:]]}"}"
    if [[ -z "${_skipEntry}" ]]; then
      printf '[%s] WARNING: ignoring empty entry in SKIP_POLICIES\n' \
        "$(date -u +%FT%TZ)" >&2
      continue
    fi
    skipPoliciesArr+=("${_skipEntry}")
  done
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
        "$(date -u +%FT%TZ)" "${p}" >&2
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
typeset -i complianceStart=0
complianceStart=$(date +%s)
typeset complianceAllSkipped=false
# The skip list is carried into the compliance row so a passing or failing
# run records which policies were excluded from the wait (the full
# manifest stays in skip-policies.txt).
typeset complianceSkipNote=''
if (( ${#skipPoliciesArr[@]} > 0 )); then
  complianceSkipNote=" (skipped by SKIP_POLICIES: ${skipPoliciesArr[*]})"
fi
while (( policyCount != prevCount )); do
  # Hard deadline: two 40m passes plus the earlier phases have to fit inside
  # the step timeout.  Without this check an overrunning compliance phase
  # leaves the pod to be terminated mid-wait, and the EXIT trap that writes
  # the JUnit report never runs.
  typeset -i passNow=0
  passNow=$(date +%s)
  if (( passNow + compliancePassBudget > stepDeadline )); then
    printf '[%s] ERROR: no time left in the step budget for another compliance pass\n' \
      "$(date -u +%FT%TZ)" >&2
    RecordResult "policies-compliant" "failed" "Compliance wait stopped after $(( (passNow - complianceStart) / 60 )) minutes: the step time budget was exhausted before the policy set stabilized${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  prevCount="${policyCount}"
  complianceAllSkipped=false

  if (( ${#skipPoliciesArr[@]} > 0 )); then
    # Fetch the full policy list first: fail hard if oc cannot reach the cluster
    typeset policyList=""
    policyList="$(oc get policies -n policies -o name)" || {
      printf '[%s] ERROR: failed to list policies in namespace "policies"\n' \
        "$(date -u +%FT%TZ)" >&2
      RecordResult "policies-compliant" "failed" "Failed to list policies in namespace policies" "$(( $(date +%s) - complianceStart ))"
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
        printf '%s\n' "Non-skipped policies failed to become compliant:" >&2
        RecordResult "policies-compliant" "failed" "Non-skipped policies failed to become compliant within 40 minutes${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
        oc get policies -n policies --ignore-not-found | FilterSkippedPolicies
        oc get policies -n policies --ignore-not-found -o yaml
        oc describe policies -n policies
        exit 1
      fi
    else
      printf '[%s] All policies are in the skip list: no policies to wait for\n' \
        "$(date -u +%FT%TZ)"
      complianceAllSkipped=true
    fi
  else
    printf '[%s] No policies to skip: waiting for ALL policies to become Compliant…\n' \
      "$(date -u +%FT%TZ)"
    if ! oc wait policies --all -n policies \
      --for jsonpath='{.status.compliant}'=Compliant \
      --timeout=40m; then
      printf '%s\n' "Policies failed to become compliant:" >&2
      RecordResult "policies-compliant" "failed" "Policies failed to become compliant within 40 minutes" "$(( $(date +%s) - complianceStart ))"
      oc get policies -n policies --ignore-not-found
      oc get policies -n policies --ignore-not-found -o yaml
      oc describe policies -n policies
      exit 1
    fi
  fi

  # Count after the pass.  A failed query is not a stable count: branch on
  # the exit status and fail the row, so a broken API cannot record a pass
  # for a policy set that was never observed.
  typeset policyCountOut=""
  typeset -i countRc=0
  policyCountOut="$(oc get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length')" || countRc=$?
  if (( countRc != 0 )) || [[ -z "${policyCountOut}" ]]; then
    printf '[%s] ERROR: failed to count policies in namespace "policies" (rc=%d)\n' \
      "$(date -u +%FT%TZ)" "${countRc}" >&2
    RecordResult "policies-compliant" "failed" "Failed to count policies in namespace policies (rc=${countRc}); the policy set state is unknown${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  policyCount="${policyCountOut}"
  printf '[%s] Compliance pass complete: %d policies in the set\n' \
    "$(date -u +%FT%TZ)" "${policyCount}"
done

if [[ "${complianceAllSkipped}" == "true" ]]; then
  RecordResult "policies-compliant" "skipped" "All policies are in the skip list: ${skipPoliciesArr[*]}" "$(( $(date +%s) - complianceStart ))"
else
  RecordResult "policies-compliant" "passed" "" "$(( $(date +%s) - complianceStart ))"
fi

true
