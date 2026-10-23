#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# --- Trace-to-file: always capture, dump on failure only ---
# Keeps xtrace out of CI build logs (policy JSON may contain sensitive
# configuration); the log is saved to artifacts only on failure.
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  _exit_code=$?
  set +x 2>/dev/null
  sed -i -E 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi' "${_xtrace_log}" 2>/dev/null || true
  if [[ ${_exit_code} -ne 0 && -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${_xtrace_log}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    echo ">>> TRACE: xtrace log saved to artifacts (exit code ${_exit_code})"
  fi
}
trap '_opp_cleanup' EXIT

cd /tmp/
git clone https://github.com/stolostron/policy-collection.git

cd policy-collection/deploy/

# If QUAY_OPERATOR_CHANNEL is set, patch the Quay operator subscription to pin the channel
if [[ -n "${QUAY_OPERATOR_CHANNEL}" ]]; then
  if [[ ! "${QUAY_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid QUAY_OPERATOR_CHANNEL: ${QUAY_OPERATOR_CHANNEL}" >&2
    exit 1
  fi
  typeset quayPolicyFile="../policygenerator/policy-sets/stable/openshift-plus/input-quay/policy-install-quay.yaml"
  sed -i "/^    name: quay-operator$/a\\    channel: ${QUAY_OPERATOR_CHANNEL}" "${quayPolicyFile}"
  grep -A5 'name: quay-operator' "${quayPolicyFile}" >> "${ARTIFACT_DIR}/channel-patches.log" 2>&1
  echo "Quay operator channel patch applied — details saved to artifacts/channel-patches.log"
fi

# If ODF_OPERATOR_CHANNEL is set, patch the ODF operator subscription to pin the channel
if [[ -n "${ODF_OPERATOR_CHANNEL}" ]]; then
  if [[ ! "${ODF_OPERATOR_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid ODF_OPERATOR_CHANNEL: ${ODF_OPERATOR_CHANNEL}" >&2
    exit 1
  fi
  typeset odfPolicyFile="../policygenerator/policy-sets/stable/openshift-plus/input-odf/policy-odf.yaml"
  sed -i "/^    name: odf-operator$/a\\    channel: ${ODF_OPERATOR_CHANNEL}" "${odfPolicyFile}"
  grep -A5 'name: odf-operator' "${odfPolicyFile}" >> "${ARTIFACT_DIR}/channel-patches.log" 2>&1
  echo "ODF operator channel patch applied — details saved to artifacts/channel-patches.log"
fi

# Remove the local-cluster exclusion from the clusters placement so
# SecuredCluster policies can target local-cluster.  In OPP single-
# cluster test environments local-cluster is the only managed cluster,
# and the default NotIn rule prevents the SecuredCluster CR from being
# created — causing stackrox-opp-readiness to timeout.
sed -i '/local-cluster.*NotIn/d' \
  ../policygenerator/policy-sets/stable/openshift-plus/input/clusters-placement.yaml

echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus > "${ARTIFACT_DIR}/deploy-output.log" 2>&1
echo "Deploy completed — output saved to artifacts/deploy-output.log"

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
      oc get quayregistry --all -n "${ns}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/quay-diagnostics.yaml" 2>&1
      oc describe quayregistry --all -n "${ns}" > "${ARTIFACT_DIR}/quay-describe.txt" 2>&1
      echo "Quay diagnostics saved to artifacts/"
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
  printf '[%s] SKIP_POLICIES set — will skip %d polic(ies):\n' \
    "$(date -u +%FT%TZ)" "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '  - %s\n' "${p}"
  done
fi

# Write the full skip manifest for auditing / artifact collection
{
  printf '# skip-policies manifest — generated %s\n' "$(date -u +%FT%TZ)"
  printf '# SKIP_POLICIES=%s\n' "${SKIP_POLICIES:-}"
  printf '# Total policies to skip: %d\n' "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '%s\n' "${p}"
  done
} > "${ARTIFACT_DIR}/skip-policies.txt"

typeset -i complianceFailed=0

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
  # Fetch the full policy list first — fail hard if oc cannot reach the cluster
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
      complianceFailed=1
      : "Non-skipped policies failed to become compliant:"
      oc get policies -n policies --ignore-not-found | grep -Ev "/(${skipRegex})$" || true
      oc get policies -n policies --ignore-not-found -o yaml > "${ARTIFACT_DIR}/policy-diagnostics.yaml" 2>&1 || true
      oc describe policies -n policies > "${ARTIFACT_DIR}/policy-describe.txt" 2>&1 || true
      echo "Policy diagnostics saved to artifacts/"
    fi
  else
    printf '[%s] All policies are in the skip list — no policies to wait for\n' \
      "$(date -u +%FT%TZ)"
  fi
else
  printf '[%s] No policies to skip — waiting for ALL policies to become Compliant…\n' \
    "$(date -u +%FT%TZ)"
  if ! oc wait policies --all -n policies \
    --for jsonpath='{.status.compliant}'=Compliant \
    --timeout=40m; then
    complianceFailed=1
    : "Policies failed to become compliant:"
    oc get policies -n policies --ignore-not-found || true
    oc get policies -n policies --ignore-not-found -o yaml > "${ARTIFACT_DIR}/policy-diagnostics.yaml" 2>&1 || true
    oc describe policies -n policies > "${ARTIFACT_DIR}/policy-describe.txt" 2>&1 || true
    echo "Policy diagnostics saved to artifacts/"
  fi
fi

# ── XML escaping helper ─────────────────────────────────────────────
# Escapes the five XML special characters so user-controlled values
# (policy names, compliance status) can be safely interpolated into
# JUnit XML attributes and text content.
_xmlesc() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# ── Generate per-policy JUnit XML ────────────────────────────────────
# Emit one <testcase> per policy so CI dashboards show individual
# policy compliance rather than a single aggregate pass/fail.
typeset junitFile="${ARTIFACT_DIR}/junit_acm_policies.xml"
typeset -r SUITE_NAME="lp-interop--OPP--acm-policies"
typeset -i junitTests=0
typeset -i junitFailures=0
typeset -i junitSkipped=0
typeset testcaseXml=""

# Query per-policy compliance status — fail hard if the cluster is unreachable
# so CI sees a real failure instead of a silent 0-test JUnit.
typeset policyStatusJson=""
set +x  # avoid tracing policy JSON content
if ! policyStatusJson="$(oc get policies -n policies -o json 2>/dev/null)"; then
  set -x
  printf '[%s] ERROR: failed to query policies for JUnit generation\n' \
    "$(date -u +%FT%TZ)" >&2
  # Emit an error JUnit so CI sees a failure, not a 0-test pass
  typeset _tmpjunit="${ARTIFACT_DIR}/.junit_acm_policies.tmp.$$"
  cat > "${_tmpjunit}" <<'EREOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="lp-interop--OPP--acm-policies" tests="1" failures="1">
  <testcase name="policy-query" classname="lp-interop--OPP--acm-policies">
    <failure message="oc get policies failed">Failed to query policies from the cluster</failure>
  </testcase>
</testsuite>
EREOF
  mv -f "${_tmpjunit}" "${ARTIFACT_DIR}/junit_acm_policies.xml"
  exit 1
fi

if [[ -n "${policyStatusJson}" ]]; then
  # Capture jq output into a variable and check its exit status so that
  # malformed JSON is caught instead of silently producing zero testcases.
  typeset policyLines=""
  if ! policyLines="$(echo "${policyStatusJson}" | jq -r '.items[] | "\(.metadata.name)|\(.status.compliant // "unknown")"')"; then
    junitTests+=1
    junitFailures+=1
    testcaseXml+="    <testcase name=\"jq-parse-policies\" classname=\"${SUITE_NAME}\">
      <failure message=\"jq failed to parse policy JSON\">policyStatusJson was not valid JSON or had an unexpected schema</failure>
    </testcase>
"
  else
    while IFS='|' read -r pName pCompliant; do
      [[ -z "${pName}" ]] && continue
      junitTests+=1

      # Check whether this policy was skipped
      typeset _skip=false
      for _sp in "${skipPoliciesArr[@]}"; do
        [[ "${_sp}" == "${pName}" ]] && { _skip=true; break; }
      done

      if [[ "${_skip}" == "true" ]]; then
        junitSkipped+=1
        testcaseXml+="    <testcase name=\"$(_xmlesc "${pName}")\" classname=\"${SUITE_NAME}\">
      <skipped message=\"Policy in SKIP_POLICIES list\"/>
    </testcase>
"
      elif [[ "${pCompliant}" == "Compliant" ]]; then
        testcaseXml+="    <testcase name=\"$(_xmlesc "${pName}")\" classname=\"${SUITE_NAME}\"/>
"
      else
        junitFailures+=1
        testcaseXml+="    <testcase name=\"$(_xmlesc "${pName}")\" classname=\"${SUITE_NAME}\">
      <failure message=\"Policy status: $(_xmlesc "${pCompliant:-unknown}")\">Policy $(_xmlesc "${pName}") is $(_xmlesc "${pCompliant:-unknown}")</failure>
    </testcase>
"
      fi
    done <<< "${policyLines}"
  fi
fi
set -x  # Re-enable xtrace after policy JSON processing

# Atomic JUnit write: temp file + mv prevents partial writes on failure.
typeset _tmpjunit2="${ARTIFACT_DIR}/.junit_acm_policies.tmp.$$"
if ! cat > "${_tmpjunit2}" <<JUNIT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${SUITE_NAME}" tests="${junitTests}" failures="${junitFailures}" skipped="${junitSkipped}">
${testcaseXml}</testsuite>
JUNIT_EOF
then
  printf '[%s] ERROR: failed to write JUnit XML to %s\n' \
    "$(date -u +%FT%TZ)" "${_tmpjunit2}" >&2
  exit 1
fi
mv -f "${_tmpjunit2}" "${junitFile}"

printf '[%s] JUnit: %d tests, %d failures, %d skipped → %s\n' \
  "$(date -u +%FT%TZ)" "${junitTests}" "${junitFailures}" "${junitSkipped}" "${junitFile}"

# ── Exit with the original compliance outcome ────────────────────────
if (( complianceFailed || junitFailures )); then
  exit 1
fi
