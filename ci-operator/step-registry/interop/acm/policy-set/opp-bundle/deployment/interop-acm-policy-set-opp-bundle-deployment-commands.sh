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
# Bounded oc get helper: cap blocking calls by remaining step budget with 120s reserve for JUnit/diagnostics (thread PRRT_kwDOBHvUUM65TpMM)
_oc_get_bounded() {
  typeset -i _now
  _now=$(date +%s)
  typeset -i _remain=$(( stepDeadline - _now - 120 ))
  (( _remain < 10 )) && _remain=10
  timeout "${_remain}s" oc "$@"
}
_oc_get_json_bounded() {
  typeset -i _now
  _now=$(date +%s)
  typeset -i _remain=$(( stepDeadline - _now - 120 ))
  (( _remain < 10 )) && _remain=10
  timeout "${_remain}s" oc get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}'
}

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
# Report name the post-processing helper merges into and writes to the
# SHARED_DIR root; the EXIT-trap fallback copy looks for it there.
typeset mergedJunitFile='junit--interop-acm-policy-set-opp-bundle-deployment.xml'

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

# Put this step's report where CI-operator collects it.  CI-operator supports
# a flat SHARED_DIR only: its state collector reads the files directly under
# it and skips directories, so a raw copy into ${SHARED_DIR}/junit/ is never
# picked up.  On success the post-processing helper has already written the
# merged report to the SHARED_DIR root and this returns without copying; when
# the helper was unavailable or failed, the raw report goes to that root
# instead, so a failing run still carries its evidence.
# shellcheck disable=SC2317
_propagate_junit () {
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    if [[ -s "${SHARED_DIR}/${mergedJunitFile}" ]]; then
        return 0
    fi
    cp "${junitFile}" "${SHARED_DIR}/" || true
}

# Install minimal JUnit trap before helper download: truncated download would exit via set -e before full EXIT trap, leaving no report
trap '{( set +e; GenerateJunit; _propagate_junit; true )}' EXIT
# Load ExitTrap library for JUnit XML post-processing at script level
# (must be loaded before trap can fire to avoid secondary errors).
typeset _etHelperScript=""
typeset -i _etHelperRc=0
typeset -a _fURL=()
type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
typeset _etHelperStderr=""
_etHelperStderr=$(mktemp)
_etHelperScript="$("${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/2420b542141e9009f29ce02551244ebc43ed7060/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh 2>"${_etHelperStderr}")" || _etHelperRc=$?
if (( _etHelperRc == 0 )) && [[ -n "${_etHelperScript}" ]]; then
    eval "${_etHelperScript}"
else
    echo "WARNING: ExitTrap helper download failed (rc=${_etHelperRc}); JUnit will be raw only" >&2
fi
rm -f "${_etHelperStderr}"
# Validate helper download completeness: truncated download exits via set -e but minimal trap already installed
if ! type -t ExitTrap--PostProcessPrep 1>/dev/null; then
    echo "WARNING: ExitTrap helper download incomplete; JUnit will be raw only" >&2
fi

# Post-process the JUnit XML for Component Readiness routing.  This runs from
# the EXIT trap, which clears errexit first, so the helper is called
# unguarded: `helper ... || warn` would disable errexit inside the helper and
# let a failed merge continue into its archive and shared-copy steps.  The
# status is inspected instead, and an unloaded helper (download failure) or a
# post-processing failure is warned about without overwriting the script's
# exit status.  The merged file name is passed explicitly: the library default
# (jUnit.xml) is not picked up by the prow JUnit viewer (lowercase junit
# prefix required) and collides with other steps in shared storage.
PostProcessJunit () {
    typeset -i postProcessRc=0
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        ExitTrap--PostProcessPrep "${mergedJunitFile}"
        postProcessRc=$?
        if (( postProcessRc != 0 )); then
            echo "WARNING: junit post-processing failed (rc=${postProcessRc})" >&2
        fi
    else
        echo "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
    true
}

# Order matters: the raw report is generated first, the helper merges it and
# writes the merged report to the SHARED_DIR root, and the fallback copy runs
# last so it can tell whether that merged report is there.
trap '{(
    set +e
    GenerateJunit
    PostProcessJunit
    _propagate_junit
    true
)}' EXIT

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
for _channelVar in LPC_LP_OPP__QUAY__OPERATOR_CHANNEL LPC_LP_OPP__ODF__OPERATOR_CHANNEL; do
  typeset _channelVal="${!_channelVar}"
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
    -p "$(jq -cn --arg ch "${channel}" '{spec:{channel:$ch}}')"; then
    printf '%s\n' "Error: failed to patch subscription ${subNamespace}/${subName} to channel ${channel}" >&2
    return 1
  fi
  : "Pinned subscription ${subNamespace}/${subName} to channel ${channel}"
}

# A nonzero deploy.sh status exits here under errexit, before the deployment
# row is recorded, which would leave the JUnit trap reporting the check as
# skipped with no failure row.  Record the failure, then exit as before.
typeset -i deployStart=0
deployStart=$(date +%s)
if ! oc create namespace policies --dry-run=client -o yaml | oc apply -f - 1>/dev/null; then
  RecordResult "openshift-plus-policy-set-deployed" "failed" "failed to create namespace policies" "$(( $(date +%s) - deployStart ))"
  exit 1
fi
if ! echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus; then
  RecordResult "openshift-plus-policy-set-deployed" "failed" "deploy.sh returned a nonzero status; the openshift-plus policy set was not submitted" "$(( $(date +%s) - deployStart ))"
  exit 1
fi

# openshift-plus generates ~25 policies; require 4+ before oc wait to avoid
# racing the GitOps Subscription propagation (stolostron/policy-collection#174)
typeset -i expectedMinPolicies=4
typeset -i pollDeadline=$((SECONDS + 600))
typeset -i policyGateStart=0
policyGateStart=$(date +%s)
typeset policyCountJson=''
typeset -i policyCountRc=0
while true; do
  typeset -i _pollRemain=$(( pollDeadline - SECONDS ))
  typeset -i _stepRemain=$(( stepDeadline - $(date +%s) - 120 ))
  (( _pollRemain < 10 )) && _pollRemain=10
  (( _stepRemain < 10 )) && _stepRemain=10
  typeset -i _queryTimeout=${_pollRemain}
  (( _queryTimeout > _stepRemain )) && _queryTimeout=${_stepRemain}
  policyCountRc=0
  policyCountJson="$(timeout "${_queryTimeout}s" oc get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length')" || policyCountRc=$?
  if (( policyCountRc != 0 )); then
    printf '%s\n' "Error: failed to query policies (rc=${policyCountRc})" >&2
    RecordResult "openshift-plus-policy-set-deployed" "failed" "failed to query policies in namespace policies (rc=${policyCountRc})" "$(( $(date +%s) - policyGateStart ))"
    exit 1
  fi
  if (( SECONDS > pollDeadline )); then
    printf '%s\n' "Error: fewer than ${expectedMinPolicies} policies after 10 minutes" >&2
    RecordResult "openshift-plus-policy-set-deployed" "failed" "Fewer than ${expectedMinPolicies} policies in namespace policies after 10 minutes" "$(( $(date +%s) - policyGateStart ))"
    exit 1
  fi
  if (( policyCountJson >= expectedMinPolicies )); then
    break
  fi
  if (( SECONDS > pollDeadline )); then
    printf '%s\n' "Error: fewer than ${expectedMinPolicies} policies after 10 minutes" >&2
    RecordResult "openshift-plus-policy-set-deployed" "failed" "Fewer than ${expectedMinPolicies} policies in namespace policies after 10 minutes" "$(( $(date +%s) - policyGateStart ))"
    exit 1
  fi
  typeset -i _gateSleepRemain=$(( stepDeadline - $(date +%s) - 30 ))
  if (( _gateSleepRemain <= 0 )); then
    printf '%s\n' "Error: step budget exhausted during policy gate" >&2
    RecordResult "openshift-plus-policy-set-deployed" "failed" "step budget exhausted during policy gate" "$(( $(date +%s) - policyGateStart ))"
    exit 1
  fi
  typeset -i _gateSleep=5
  (( _gateSleep > _gateSleepRemain )) && _gateSleep=${_gateSleepRemain}
  sleep "${_gateSleep}"
done
RecordResult "openshift-plus-policy-set-deployed" "passed" "" "$(( $(date +%s) - policyGateStart ))"

# Apply requested channel overrides to the deployed OLM subscriptions.  The
# ODF pin runs before the Quay pin on purpose: an ODF subscription installed
# from the catalog default channel has to be corrected before the Quay pin
# (whose wait can take up to ten minutes and exits on failure) and before the
# Quay readiness wait below, so a default-channel ODF install failure cannot
# hold the ODF correction behind either of them.
if [[ -n "${LPC_LP_OPP__ODF__OPERATOR_CHANNEL}" ]]; then
  typeset -i odfPinStart=0
  odfPinStart=$(date +%s)
  if PinSubscriptionChannel openshift-storage odf-operator "${LPC_LP_OPP__ODF__OPERATOR_CHANNEL}"; then
    RecordResult "subscription-channel-pin-openshift-storage-odf-operator" "passed" "" "$(( $(date +%s) - odfPinStart ))"
  else
    RecordResult "subscription-channel-pin-openshift-storage-odf-operator" "failed" "Could not pin subscription openshift-storage/odf-operator to channel ${LPC_LP_OPP__ODF__OPERATOR_CHANNEL}" "$(( $(date +%s) - odfPinStart ))"
    exit 1
  fi
else
  RecordResult "subscription-channel-pin-openshift-storage-odf-operator" "skipped" "LPC_LP_OPP__ODF__OPERATOR_CHANNEL not set"
fi
if [[ -n "${LPC_LP_OPP__QUAY__OPERATOR_CHANNEL}" ]]; then
  typeset -i quayPinStart=0
  quayPinStart=$(date +%s)
  if PinSubscriptionChannel local-quay quay-operator "${LPC_LP_OPP__QUAY__OPERATOR_CHANNEL}"; then
    RecordResult "subscription-channel-pin-local-quay-quay-operator" "passed" "" "$(( $(date +%s) - quayPinStart ))"
  else
    RecordResult "subscription-channel-pin-local-quay-quay-operator" "failed" "Could not pin subscription local-quay/quay-operator to channel ${LPC_LP_OPP__QUAY__OPERATOR_CHANNEL}" "$(( $(date +%s) - quayPinStart ))"
    exit 1
  fi
else
  RecordResult "subscription-channel-pin-local-quay-quay-operator" "skipped" "LPC_LP_OPP__QUAY__OPERATOR_CHANNEL not set"
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
    -p '[{"op":"test","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1/key","value":"local-cluster"},{"op":"test","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1/operator","value":"NotIn"},{"op":"test","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1/values","value":["true"]},{"op":"remove","path":"/spec/predicates/0/requiredClusterSelector/labelSelector/matchExpressions/1"}]'; then
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
typeset quayPrimaryNs="local-quay"
typeset -a quayOtherNamespacesArr=(quay openshift-quay quay-enterprise)
typeset quayFound=false
typeset -i quayStart=0
quayStart=$(date +%s)
typeset -i quayDeadline=$(( quayStart + 600 ))
typeset ns=''
typeset -i quayOutOfScopeTotal=0
# Poll for QuayRegistry with bounded deadline: policy-install-quay depends on odf-status, so registry may appear after initial scan
typeset _quayPollInterval=10
while (( $(date +%s) < quayDeadline )) && [[ "${quayFound}" == "false" ]]; do
  # Check only the intended namespace for success; other namespaces are out of scope
  ns="${quayPrimaryNs}"
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
  else
    typeset -i quayItemCount=0
    if ! quayItemCount="$(printf '%s' "${quayJson}" | jq '.items | length')"; then
      printf '%s\n' "Warning: could not count QuayRegistry objects in namespace ${ns}; skipping it" >&2
    elif (( quayItemCount > 0 )); then
      : "Found Quay Operator deployment in namespace ${ns}, waiting for ready condition"
      if ! oc wait quayregistry --all -n "${ns}" \
        --for condition=Available=True \
        --timeout=10m; then
        RecordResult "quay-registry-available" "failed" "QuayRegistry in namespace ${ns} did not become Available within 10 minutes" "$(( $(date +%s) - quayStart ))"
      oc get quayregistry -n "${ns}" --ignore-not-found -o yaml || true
      oc describe quayregistry -n "${ns}" || true
      exit 1
    fi
    RecordResult "quay-registry-available" "passed" "" "$(( $(date +%s) - quayStart ))"
    quayFound=true
    fi
  fi
  # Out-of-scope check: count registries in other namespaces for diagnostic only, without raw identifiers
  if [[ "${quayFound}" == "false" ]]; then
    typeset -i quayOutOfScopeInPass=0
    for ns in "${quayOtherNamespacesArr[@]}"; do
      typeset outJson="" outRc=0 outCount=0
      outJson="$(oc get quayregistry -n "${ns}" -o json 2>&1)" || outRc=$?
      if (( outRc != 0 )); then
        continue
      fi
      if ! outCount="$(printf '%s' "${outJson}" | jq '.items | length' 2>/dev/null)"; then
        continue
      fi
      if (( outCount > 0 )); then
        quayOutOfScopeInPass=$((quayOutOfScopeInPass + outCount))
      fi
    done
    if (( quayOutOfScopeInPass > 0 )); then
      quayOutOfScopeTotal=$((quayOutOfScopeTotal + quayOutOfScopeInPass))
      printf '%s\n' "Note: found ${quayOutOfScopeInPass} out-of-scope QuayRegistry object(s) in other namespaces (not satisfying check in ${quayPrimaryNs})" >&2
    fi
  fi
  # Poll interval if no registry found in this pass and deadline not yet reached
  if [[ "${quayFound}" == "false" ]] && (( $(date +%s) < quayDeadline )); then
    sleep "${_quayPollInterval}"
  fi
done
if [[ "${quayFound}" == "false" ]]; then
  if (( quayOutOfScopeTotal > 0 )); then
    printf '%s\n' "Warning: no QuayRegistry found in intended namespace ${quayPrimaryNs} (found ${quayOutOfScopeTotal} out-of-scope object(s) in other namespaces)" >&2
  else
    printf '%s\n' "Warning: no QuayRegistry found in namespace ${quayPrimaryNs}" >&2
  fi
  RecordResult "quay-registry-available" "skipped" "No QuayRegistry found in namespace ${quayPrimaryNs}" "$(( $(date +%s) - quayStart ))"
fi

# ── LPC_LP_OPP__ACM_PS__SKIP_POLICIES handling ──────────────────────────────────────────
# LPC_LP_OPP__ACM_PS__SKIP_POLICIES: comma-separated policy names to exclude
# from the compliance wait.  Empty (default) means wait for ALL policies.
# Non-existent policy names produce a warning, not a failure.
typeset -a skipPoliciesArr=()
if [[ -n "${LPC_LP_OPP__ACM_PS__SKIP_POLICIES}" ]]; then
  typeset _skipNormalized="${LPC_LP_OPP__ACM_PS__SKIP_POLICIES//$'\n'/','}"
  IFS=',' read -ra _skipRawArr <<< "${_skipNormalized}"
  for _skipEntry in "${_skipRawArr[@]}"; do
    # Trim surrounding whitespace: an untrimmed entry ("a, b" yields " b")
    # would never match a policy name and would silently skip nothing.
    _skipEntry="${_skipEntry#"${_skipEntry%%[![:space:]]*}"}"
    _skipEntry="${_skipEntry%"${_skipEntry##*[![:space:]]}"}"
    if [[ -z "${_skipEntry}" ]]; then
      printf '[%s] WARNING: ignoring empty entry in LPC_LP_OPP__ACM_PS__SKIP_POLICIES\n' \
        "$(date -u +%FT%TZ)" >&2
      continue
    fi
    skipPoliciesArr+=("${_skipEntry}")
  done
  printf '[%s] LPC_LP_OPP__ACM_PS__SKIP_POLICIES set: will skip %d polic(ies):\n' \
    "$(date -u +%FT%TZ)" "${#skipPoliciesArr[@]}" >&2
  for p in "${skipPoliciesArr[@]}"; do
    printf '  - %s\n' "${p}" >&2
  done
fi

# Write the full skip manifest for auditing / artifact collection
{
  printf '# skip-policies manifest: generated %s\n' "$(date -u +%FT%TZ)"
  printf '# LPC_LP_OPP__ACM_PS__SKIP_POLICIES=%s\n' "${LPC_LP_OPP__ACM_PS__SKIP_POLICIES}"
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
  allPolicies="$(_oc_get_bounded get policies -n policies -o name)" || true
  for p in "${skipPoliciesArr[@]}"; do
    if ! PolicyExists "${p}" <<< "${allPolicies}"; then
      printf '[%s] WARNING: policy "%s" from LPC_LP_OPP__ACM_PS__SKIP_POLICIES not found in cluster (ignoring)\n' \
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
# previous pass.  An equal count across one pass only proves that the count
# stopped moving for the duration of that pass, not that GitOps finished
# creating the set: the set can stall below its final size for longer than
# a pass, and a pass over an already-compliant partial set returns at once.
# Succeed only after a pass ran against a set carrying the same names that
# then stayed unchanged across several spaced polls.  A same-size swap is not
# completion either: when one policy is replaced while the pass runs, the
# count is unchanged but the replacement was never waited on.
typeset -i compliancePollTarget=3
typeset -i compliancePollIntervalSeconds=30
typeset complianceStableSet=''
typeset -i complianceStableCount=0

# Read the policy name set, sorted so that two reads compare equal
# regardless of the order the API returns list items in.  A read that fails
# is not an unchanged set, so it returns non-zero instead of printing an
# empty set.
PolicyNameSet () {
  typeset namesJson=''
  typeset -i namesRc=0
  namesJson="$(_oc_get_bounded get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}')" || namesRc=$?
  if (( namesRc != 0 )) || [[ -z "${namesJson}" ]]; then
    printf '[%s] ERROR: failed to read the policy name set (rc=%d)\n' \
      "$(date -u +%FT%TZ)" "${namesRc}" >&2
    return 1
  fi
  printf '%s' "${namesJson}" | jq -r '.[]' | LC_ALL=C sort
}

# Policy count, with the read failure surfaced: a failed query is not a
# stable count.
PolicyCount () {
  typeset countJson=''
  typeset -i countRc=0
  countJson="$(_oc_get_bounded get policies -n policies -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length')" || countRc=$?
  if (( countRc != 0 )) || [[ -z "${countJson}" ]]; then
    return 1
  fi
  printf '%s' "${countJson}"
}

# Poll until the policy name set has not changed across
# compliancePollTarget consecutive polls spaced by
# compliancePollIntervalSeconds, so a GitOps set that is still propagating is
# not accepted as complete.  On success complianceStableSet and
# complianceStableCount carry the observation.  Returns 1 when a poll fails
# and 2 when the step budget runs out while polling.
ReadStablePolicySet () {
  typeset phase="${1}"
  typeset nextSet=''
  typeset -i unchangedPolls=0
  complianceStableSet=''
  complianceStableCount=0
  while (( unchangedPolls < compliancePollTarget )); do
    if ! nextSet="$(PolicyNameSet)"; then
      printf '[%s] ERROR: could not read the policy name set while proving set stability %s\n' \
        "$(date -u +%FT%TZ)" "${phase}" >&2
      return 1
    fi
    if [[ -z "${nextSet}" ]]; then
      printf '[%s] ERROR: the policy name set is empty while proving set stability %s\n' \
        "$(date -u +%FT%TZ)" "${phase}" >&2
      return 1
    fi
    if [[ "${nextSet}" == "${complianceStableSet}" ]]; then
      unchangedPolls=$(( unchangedPolls + 1 ))
    else
      # A changed set restarts the count: the earlier observations say
      # nothing about the set that exists now.
      complianceStableSet="${nextSet}"
      unchangedPolls=1
    fi
    if (( unchangedPolls < compliancePollTarget )); then
      typeset -i pollNow=0
      pollNow=$(date +%s)
      if (( pollNow + compliancePollIntervalSeconds > stepDeadline )); then
        printf '[%s] ERROR: the step time budget ran out while proving the policy set stable %s\n' \
          "$(date -u +%FT%TZ)" "${phase}" >&2
        return 2
      fi
      sleep "${compliancePollIntervalSeconds}"
    fi
  done
  complianceStableCount=$(printf '%s\n' "${complianceStableSet}" | wc -l)
  return 0
}

# Count-based gates cannot see a bundle that stalls below its final size, so
# the expected membership comes from the applied PolicySets: every policy a
# PolicySet lists has to be present before compliance is accepted.  The list
# is read once per acceptance check, and a PolicySet-as-read failure retries and
# then fails the row: without the membership the stable set cannot be compared
# against the applied PolicySets, which is the only signal that closes the
# stall-below-final-size race.
ExpectedPolicyNames () {
  typeset setsJson=''
  typeset -i _ep_now
  _ep_now=$(date +%s)
  typeset -i _ep_remain=$(( stepDeadline - _ep_now - 120 ))
  (( _ep_remain < 10 )) && _ep_remain=10
  setsJson="$(timeout "${_ep_remain}s" oc get policysets.policy.open-cluster-management.io -n policies -o json)" || return 1
  if [[ -z "${setsJson}" ]]; then
    return 1
  fi
  printf '%s' "${setsJson}" | jq -r '
    [ .items[]?.spec.policies[]?
      | if type == "string"
          then .
          else (select(.kind == "Policy")
                | select((.namespace // "policies") == "policies")
                | .name)
        end ]
    | unique
    | .[]
  '
}

# Membership read with retries.  A read that cannot be completed fails the
# row instead of falling back to count and stability alone: a partial set that
# stops changing is indistinguishable from a complete one, which is the race
# this membership check exists to close.
ExpectedPolicyNamesRetry () {
  typeset phase="${1}"
  typeset names=''
  typeset -i try=0 rc=0
  for try in 1 2 3; do
    if names="$(ExpectedPolicyNames)"; then
      printf '%s' "${names}"
      return 0
    else
      # $? here is the failed condition's status; after the fi it would be the
      # if compound's own (successful) status.
      rc=$?
    fi
    if (( try < 3 )); then
      printf '[%s] WARNING: could not read PolicySet membership %s (attempt %d/3), retrying\n' \
        "$(date -u +%FT%TZ)" "${phase}" "${try}" >&2
      typeset -i _retryNow=0
      _retryNow=$(date +%s)
      if (( _retryNow + 10 > stepDeadline - 30 )); then
        printf '[%s] WARNING: not enough time for retry sleep before step deadline, skipping sleep\n' "$(date -u +%FT%TZ)" >&2
      else
        sleep 10
      fi
    fi
  done
  printf '[%s] ERROR: could not read PolicySet membership %s (rc=%d)\n' \
    "$(date -u +%FT%TZ)" "${phase}" "${rc}" >&2
  return "${rc}"
}

# Membership the observed set is missing: expected names (minus the skip list)
# that the observed set does not carry.  Both lists are passed as arguments
# and compared as sorted name sets.
MissingExpectedPolicies () {
  typeset expectedRaw="${1}"
  typeset observedRaw="${2}"
  typeset expectedFiltered=''
  expectedFiltered="$(printf '%s\n' "${expectedRaw}" | sed 's|^|policy/|' | FilterSkippedPolicies | sed 's|^policy/||')" || expectedFiltered=''
  if [[ -z "${expectedFiltered}" ]]; then
    return 0
  fi
  LC_ALL=C comm -23 \
    <(printf '%s\n' "${expectedFiltered}" | LC_ALL=C sort) \
    <(printf '%s\n' "${observedRaw}" | LC_ALL=C sort) | sed '/^$/d'
}

typeset -i policyCount=0
typeset -i prevCount=0
typeset prevSet=''
typeset -i complianceStart=0
complianceStart=$(date +%s)
typeset complianceAllSkipped=false
# The skip list is carried into the compliance row so a passing or failing
# run records which policies were excluded from the wait (the full
# manifest stays in skip-policies.txt).
typeset complianceSkipNote=''
if (( ${#skipPoliciesArr[@]} > 0 )); then
  complianceSkipNote=" (skipped by LPC_LP_OPP__ACM_PS__SKIP_POLICIES: ${skipPoliciesArr[*]})"
fi
# The stability evidence that let the compliance row pass is carried into the
# row itself, so a green run records which observation it was accepted on.
typeset complianceStabilityNote=''
# Carried into the budget-exhaustion row: a set that stabilized below the
# applied PolicySet membership is a different failure from a set that never
# stabilized, and the row has to say which one it was.
typeset missingExpectedNote=''

# Require the set to stop growing before the first compliance pass, and
# start the pass loop from the count observed there instead of -1: a pass
# against an already-stable set must be able to finish the phase on its own,
# and forcing a second pass by seeding prevCount with a sentinel charged the
# step budget for a pass the stability evidence already covered.
typeset -i stableRc=0
ReadStablePolicySet "before the first compliance pass" || stableRc=$?
if (( stableRc != 0 )); then
  RecordResult "policies-compliant" "failed" "Could not observe a stable policy set before the first compliance pass (rc=${stableRc}): the set may still be growing, so compliance cannot be accepted${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
  exit 1
fi
policyCount="${complianceStableCount}"
prevCount="${policyCount}"
: "Policy set stable at ${policyCount} policies before the first compliance pass"

while :; do
  # Hard deadline: two 40m passes plus the earlier phases have to fit inside
  # the step timeout.  Without this check an overrunning compliance phase
  # leaves the pod to be terminated mid-wait, and the EXIT trap that writes
  # the JUnit report never runs.
  typeset -i passNow=0
  passNow=$(date +%s)
  typeset -i _remainingBudget=$(( stepDeadline - passNow - 120 ))
  typeset -i _minPassBudget=$(( (compliancePollTarget - 1) * compliancePollIntervalSeconds ))
  (( _minPassBudget < 60 )) && _minPassBudget=60
  if (( _remainingBudget < _minPassBudget )); then
    printf '[%s] ERROR: no time left in the step budget for another compliance pass (remaining %ds)\n' \
      "$(date -u +%FT%TZ)" "${_remainingBudget}" >&2
    RecordResult "policies-compliant" "failed" "Compliance wait stopped after $(( (passNow - complianceStart) / 60 )) minutes: the step time budget was exhausted before the policy set stabilized${missingExpectedNote}${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  prevCount="${policyCount}"
  # Expected bundle membership, read before the pass: a set that is stable at
  # a smaller size than the applied PolicySets list is not a complete
  # deployment, whatever its count.  A read that cannot be completed is
  # retried and then fails the row: accepting on count and stability alone is
  # exactly the race this membership check exists to close, because a partial
  # set that stops changing is indistinguishable from a complete one.
  typeset expectedPolicies=''
  if ! expectedPolicies="$(ExpectedPolicyNamesRetry "before the compliance pass")"; then
    RecordResult "policies-compliant" "failed" "Could not read PolicySet membership before the compliance pass; the stable set cannot be compared against the applied PolicySets${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  # Names the pass below actually covers.  `oc wait --all` and the explicit
  # name list both only consider policies that exist when the wait starts, so
  # a policy replaced by another during the pass leaves the count unchanged
  # while the replacement policy was never waited on.  Capture the identities
  # so the post-pass comparison can tell an unchanged set from a swap.
  typeset complianceWaitSet=''
  if ! prevSet="$(PolicyNameSet)"; then
    RecordResult "policies-compliant" "failed" "Failed to read the policy name set before the compliance pass; the set the wait covers is unknown${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  complianceAllSkipped=false

  if (( ${#skipPoliciesArr[@]} > 0 )); then
    # Fetch the full policy list first: fail hard if oc cannot reach the cluster
    typeset policyList=""
    policyList="$(_oc_get_bounded get policies -n policies -o name)" || {
      printf '[%s] ERROR: failed to list policies in namespace "policies"\n' \
        "$(date -u +%FT%TZ)" >&2
      RecordResult "policies-compliant" "failed" "Failed to list policies in namespace policies" "$(( $(date +%s) - complianceStart ))"
      exit 1
    }
    typeset -a applyPoliciesArr=()
    mapfile -t applyPoliciesArr < <(printf '%s\n' "${policyList}" | FilterSkippedPolicies)

    if (( ${#applyPoliciesArr[@]} > 0 )); then
      : "Waiting for ${#applyPoliciesArr[@]} non-skipped polic(ies) to become Compliant…"
      typeset -i _waitNow=0
      _waitNow=$(date +%s)
      _remainingBudget=$(( stepDeadline - _waitNow - 120 ))
      (( _remainingBudget < 10 )) && _remainingBudget=10
      typeset -i _waitTimeout=${_remainingBudget}
      (( _waitTimeout > 2400 )) && _waitTimeout=2400
      if ! oc wait -n policies \
        --for jsonpath='{.status.compliant}'=Compliant \
        --timeout="${_waitTimeout}s" "${applyPoliciesArr[@]}"; then
        printf '%s\n' "Non-skipped policies failed to become compliant:" >&2
        RecordResult "policies-compliant" "failed" "Non-skipped policies failed to become compliant within 40 minutes${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
        typeset -i _diagDeadline=$(( stepDeadline - 30 ))
        typeset -i _diagRemain=$(( _diagDeadline - $(date +%s) ))
        if (( _diagRemain > 0 )); then
          typeset -i _t=$(( _diagRemain < 30 ? _diagRemain : 30 ))
          timeout "${_t}s" oc get policies -n policies --ignore-not-found | FilterSkippedPolicies || true
          _diagRemain=$(( _diagDeadline - $(date +%s) ))
          if (( _diagRemain > 0 )); then
            _t=$(( _diagRemain < 60 ? _diagRemain : 60 ))
            timeout "${_t}s" oc get policies -n policies --ignore-not-found -o yaml || true
          fi
          _diagRemain=$(( _diagDeadline - $(date +%s) ))
          if (( _diagRemain > 0 )); then
            _t=$(( _diagRemain < 60 ? _diagRemain : 60 ))
            timeout "${_t}s" oc describe policies -n policies || true
          fi
        fi
        exit 1
      fi
    else
      : "All policies are in the skip list: no policies to wait for"
      complianceAllSkipped=true
    fi
  else
    : "No policies to skip: waiting for ALL policies to become Compliant…"
    typeset -i _waitNow=0
    _waitNow=$(date +%s)
    _remainingBudget=$(( stepDeadline - _waitNow - 120 ))
    (( _remainingBudget < 10 )) && _remainingBudget=10
    typeset -i _waitTimeout=${_remainingBudget}
    (( _waitTimeout > 2400 )) && _waitTimeout=2400
    if ! oc wait policies --all -n policies \
      --for jsonpath='{.status.compliant}'=Compliant \
      --timeout="${_waitTimeout}s"; then
      printf '%s\n' "Policies failed to become compliant:" >&2
      RecordResult "policies-compliant" "failed" "Policies failed to become compliant within 40 minutes" "$(( $(date +%s) - complianceStart ))"
      typeset -i _diagDeadline=$(( stepDeadline - 30 ))
      typeset -i _diagRemain=$(( _diagDeadline - $(date +%s) ))
      if (( _diagRemain > 0 )); then
        typeset -i _t=$(( _diagRemain < 30 ? _diagRemain : 30 ))
        timeout "${_t}s" oc get policies -n policies --ignore-not-found || true
        _diagRemain=$(( _diagDeadline - $(date +%s) ))
        if (( _diagRemain > 0 )); then
          _t=$(( _diagRemain < 60 ? _diagRemain : 60 ))
          timeout "${_t}s" oc get policies -n policies --ignore-not-found -o yaml || true
        fi
        _diagRemain=$(( _diagDeadline - $(date +%s) ))
        if (( _diagRemain > 0 )); then
          _t=$(( _diagRemain < 60 ? _diagRemain : 60 ))
          timeout "${_t}s" oc describe policies -n policies || true
        fi
      fi
      exit 1
    fi
  fi

  # Verify wait-received names vs current set: if policy replaced during pass, count unchanged but replacement never waited (thread PRRT_kwDOBHvUUM65TpMc)
  if [[ "${complianceAllSkipped}" != "true" ]]; then
    # Capture wait set: for --all it's prevSet, for filtered it's applyPoliciesArr
    if (( ${#skipPoliciesArr[@]} > 0 )); then
      complianceWaitSet="$(printf '%s\n' "${applyPoliciesArr[@]}" | sed 's|.*/||' | LC_ALL=C sort)"
    else
      complianceWaitSet="${prevSet}"
    fi
  fi
  # Count after the pass.  A failed query is not a stable count: fail the
  # row, so a broken API cannot record a pass for a policy set that was
  # never observed.
  typeset policyCountOut=""
  typeset -i countRc=0
  policyCountOut="$(PolicyCount)" || countRc=$?
  if (( countRc != 0 )) || [[ -z "${policyCountOut}" ]]; then
    printf '[%s] ERROR: failed to count policies in namespace "policies" (rc=%d)\n' \
      "$(date -u +%FT%TZ)" "${countRc}" >&2
    RecordResult "policies-compliant" "failed" "Failed to count policies in namespace policies (rc=${countRc}); the policy set state is unknown${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  policyCount="${policyCountOut}"
  : "Compliance pass complete: ${policyCount} policies in the set"

  # A pass is the final one only when it ran against a set of the same size
  # and that set then stopped changing across the spaced polls.  Either
  # signal alone is not completion: a growing set means the pass never
  # covered the policies that appeared, and an equal count over one pass can
  # be a set that stalled below its final size.
  if (( policyCount != prevCount )); then
    : "Policy set changed during the pass (${prevCount} -> ${policyCount} policies); re-running the compliance wait"
    continue
  fi
  # Swap detection: if wait set differs from stable set, replacement occurred without wait (PRRT_kwDOBHvUUM65TpMc)
  if [[ -n "${complianceWaitSet}" && -n "${complianceStableSet}" ]]; then
    typeset _waitSetSorted _stableSorted _prevFilteredForSwap
    _waitSetSorted="$(printf '%s\n' "${complianceWaitSet}" | LC_ALL=C sort)"
    if (( ${#skipPoliciesArr[@]} > 0 )); then
      _stableSorted="$(printf '%s\n' "${complianceStableSet}" | FilterSkippedPolicies | LC_ALL=C sort)"
      _prevFilteredForSwap="$(printf '%s\n' "${prevSet}" | FilterSkippedPolicies | LC_ALL=C sort)"
    else
      _stableSorted="$(printf '%s\n' "${complianceStableSet}" | LC_ALL=C sort)"
      _prevFilteredForSwap="${prevSet}"
    fi
    if [[ "${_waitSetSorted}" != "${_stableSorted}" ]] && [[ "${_waitSetSorted}" != "${_prevFilteredForSwap}" ]]; then
      : "Wait set differs from stable set after pass (swap detected); re-running wait"
      policyCount="${complianceStableCount}"
      continue
    fi
  fi
  typeset -i passStableRc=0
  ReadStablePolicySet "after the compliance pass" || passStableRc=$?
  if (( passStableRc != 0 )); then
    RecordResult "policies-compliant" "failed" "Could not observe a stable policy set after the compliance pass (rc=${passStableRc}): the set may still be growing, so compliance cannot be accepted${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  if [[ "${complianceStableSet}" != "${prevSet}" ]] || (( complianceStableCount != prevCount )); then
    : "Policy set changed while proving stability (${prevCount} -> ${complianceStableCount} policies, or the names differ from the set the pass covered); re-running the compliance wait"
    policyCount="${complianceStableCount}"
    continue
  fi
  policyCount="${complianceStableCount}"
  if [[ "${complianceAllSkipped}" == "true" ]]; then
    typeset _filteredStableForSkipped=""
    _filteredStableForSkipped="$(printf '%s\n' "${complianceStableSet}" | FilterSkippedPolicies)"
    if [[ -n "${_filteredStableForSkipped}" ]]; then
      : "Stability window shows non-skipped policy present; re-running wait"
      continue
    fi
  fi
  # The membership the coverage check uses was read before the pass, so a
  # PolicySet applied during the pass is not in it: its policies could stay
  # absent through the stability window and the row would be accepted with them
  # missing.  Re-read the membership, and wait again when it changed.
  typeset refreshedPolicies=''
  if ! refreshedPolicies="$(ExpectedPolicyNamesRetry "after the compliance pass")"; then
    RecordResult "policies-compliant" "failed" "Could not re-read PolicySet membership after the compliance pass; the pass may have run against an older bundle${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  if [[ "${refreshedPolicies}" != "${expectedPolicies}" ]]; then
    : "PolicySet membership changed during the pass; re-running the compliance wait"
    continue
  fi
  # The gate is complete only when the set is stable, covers the names the
  # pass covered, and carries every policy the applied PolicySets list.
  typeset missingPolicies=''
  typeset -i _mpRc=0
  missingPolicies="$(MissingExpectedPolicies "${expectedPolicies}" "${complianceStableSet}")" || _mpRc=$?
  if (( _mpRc != 0 )); then
    RecordResult "policies-compliant" "failed" "Could not compare expected PolicySet membership with current set (comparison failed with exit ${_mpRc})" "$(( $(date +%s) - complianceStart ))"
    exit 1
  fi
  if [[ -n "${missingPolicies}" ]]; then
    : "Policy set stable at ${complianceStableCount} policies but incomplete: $(printf '%s\n' "${missingPolicies}" | wc -l) expected polic(ies) absent ($(printf '%s' "${missingPolicies}" | tr '\n' ' ')); re-running the compliance wait"
    missingExpectedNote="; the set stayed stable at ${complianceStableCount} policies without $(printf '%s\n' "${missingPolicies}" | wc -l) expected polic(ies): $(printf '%s' "${missingPolicies}" | tr '\n' ' ')"
    policyCount="${complianceStableCount}"
    continue
  fi
  if [[ -n "${expectedPolicies}" ]]; then
    complianceStabilityNote="${policyCount} policies, same name set as the compliance pass, expected PolicySet membership covered, unchanged across ${compliancePollTarget} consecutive ${compliancePollIntervalSeconds}s polls"
  else
    # The read succeeded and listed no PolicySets: some bundles deliver policies
    # without a PolicySet, and this is where the membership signal is simply
    # absent. The note says so instead of claiming a coverage that did not
    # happen; a read that failed already failed the row above.
    complianceStabilityNote="${policyCount} policies, same name set as the compliance pass, unchanged across ${compliancePollTarget} consecutive ${compliancePollIntervalSeconds}s polls, no PolicySet objects to compare against"
    printf '[%s] WARNING: no PolicySet objects in namespace policies; the compliance pass rests on the count and stability evidence only\n' \
      "$(date -u +%FT%TZ)" >&2
  fi
  break
done

if [[ "${complianceAllSkipped}" == "true" ]]; then
  RecordResult "policies-compliant" "skipped" "All policies are in the skip list: ${skipPoliciesArr[*]}" "$(( $(date +%s) - complianceStart ))"
else
  : "Policy set complete: ${complianceStabilityNote}${complianceSkipNote}"
  RecordResult "policies-compliant" "passed" "${complianceStabilityNote}${complianceSkipNote}" "$(( $(date +%s) - complianceStart ))"
fi

true
