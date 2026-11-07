#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

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
# created — causing stackrox-opp-readiness to timeout.
sed -i '/local-cluster.*NotIn/d' \
  ../policygenerator/policy-sets/stable/openshift-plus/input/clusters-placement.yaml

echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus

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
# SKIP_POLICIES: comma- or newline-separated policy names to exclude
# from the compliance wait.  Empty (default) means wait for ALL policies.
# Non-existent policy names produce a warning, not a failure.
typeset -a skipPoliciesArr=()
if [[ -n "${SKIP_POLICIES:-}" ]]; then
  # Normalize: trim whitespace (incl \r), drop empty and duplicate entries
  # with one summary warning.  No rejection: warn-only semantics preserved.
  typeset -a _rawSkipArr=()
  typeset _seenSkips='|'
  # `read` is line-oriented: splitting the whole value at once would keep
  # only the first line and silently drop every entry after the first
  # newline — those policies would then be neither normalized nor given a
  # JUnit row, and would still be waited on.  Split per line instead, so
  # newline and comma are equivalent separators.
  typeset _skipLine=''
  while IFS= read -r _skipLine; do
    typeset -a _lineSkipArr=()
    IFS=',' read -ra _lineSkipArr <<< "${_skipLine}" || true
    _rawSkipArr+=(${_lineSkipArr[@]+"${_lineSkipArr[@]}"})
  done <<< "${SKIP_POLICIES}"
  typeset -a _droppedArr=()
  for _p in "${_rawSkipArr[@]}"; do
    _p="${_p//[[:space:]]/}"
    if [[ -z "${_p}" ]]; then
      _droppedArr+=("(empty)")
      continue
    fi
    if [[ "${_seenSkips}" == *"|${_p}|"* ]]; then
      _droppedArr+=("${_p} (duplicate)")
      continue
    fi
    _seenSkips+="${_p}|"
    skipPoliciesArr+=("${_p}")
  done
  if (( ${#_droppedArr[@]} > 0 )); then
    printf '[%s] WARNING: dropped %d SKIP_POLICIES entr(ies): %s\n' \
      "$(date -u +%FT%TZ)" "${#_droppedArr[@]}" "${_droppedArr[*]}"
  fi
  printf '[%s] SKIP_POLICIES set — will skip %d polic(ies):\n' \
    "$(date -u +%FT%TZ)" "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '  - %s\n' "${p}"
  done
fi

# Write the skip manifest for auditing / artifact collection.
# The raw env value is deliberately NOT echoed: it could contain
# newlines that fabricate manifest lines; only normalized entries are
# recorded, one per line.
{
  printf '# skip-policies manifest — generated %s\n' "$(date -u +%FT%TZ)"
  printf '# Total policies to skip: %d\n' "${#skipPoliciesArr[@]}"
  for p in "${skipPoliciesArr[@]}"; do
    printf '%s\n' "${p}"
  done
} > "${ARTIFACT_DIR}/skip-policies.txt"

if (( ${#skipPoliciesArr[@]} > 0 )); then
  # Fetch the full policy list once — fail hard if oc cannot reach the
  # cluster (pre-existing semantics; a red step is the failure signal,
  # never a green artifact).  The fetch sits at the classification point
  # so "present" means "present when the compliance wait starts".
  typeset policyList=""
  policyList="$(oc get policies -n policies -o name --request-timeout=60s)" || {
    printf '[%s] ERROR: failed to list policies in namespace "policies"\n' \
      "$(date -u +%FT%TZ)" >&2
    exit 1
  }

  # Classify each configured entry by exact suffix compare and build the
  # wait list by the same exact-match filter (no regex construction: a
  # regex built from env-derived names is an injection sink, and BRE/ERE
  # engines disagree).  The wait list keeps the original -o name lines.
  typeset -a applyPoliciesArr=()
  typeset -a skipPresentArr=()
  typeset _found=false
  for p in "${skipPoliciesArr[@]}"; do
    _found=false
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      if [[ "${_line##*/}" == "${p}" ]]; then
        _found=true
        break
      fi
    done <<< "${policyList}"
    if [[ "${_found}" == true ]]; then
      skipPresentArr+=("${p}|true")
    else
      skipPresentArr+=("${p}|false")
      printf '[%s] WARNING: policy "%s" from SKIP_POLICIES not found in cluster (ignoring)\n' \
        "$(date -u +%FT%TZ)" "${p}"
    fi
  done
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _skip=false
    for p in "${skipPoliciesArr[@]}"; do
      if [[ "${_line##*/}" == "${p}" ]]; then
        _skip=true
        break
      fi
    done
    [[ "${_skip}" == false ]] && applyPoliciesArr+=("${_line}")
  done <<< "${policyList}"

  printf '# Present in cluster: %d of %d\n' \
    "$(printf '%s\n' "${skipPresentArr[@]}" | grep -c '|true$' || true)" \
    "${#skipPoliciesArr[@]}" >> "${ARTIFACT_DIR}/skip-policies.txt"

  # Emit one failing JUnit testcase per configured skip entry
  # (INTEROP-9677): while any skip remains, the skip state must be
  # countable instead of invisible.  Rows are keyed to the CONFIGURED
  # list (presence only informs the message), sorted for run-to-run
  # determinism, and carry no timestamps.  The step still exits 0;
  # these are visibility failures, not step failures.
  #
  # Deliberate deviation from the sibling convention: this artifact is
  # NOT propagated to ${SHARED_DIR}/junit.  interop-opp-skip-ratio-gate
  # counts <skipped> (not failures); propagating failure rows would
  # inflate the gate denominator and mask real skip-ratio breaches.
  # Policy skips are counted via this per-step artifact instead.
  _skip_xml_escape() {
    # Same idiom as interop-tests-opp-quay-smoke (& first)
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<< "${1}"
  }
  _skip_junit_emit() (
    # Subshell body: set +e is scoped here so emission trouble can never
    # change the step's exit semantics.
    set +e
    typeset _f="${ARTIFACT_DIR}/junit_skip_policies.xml"
    # Pre-seed a distinct evidence-incomplete failing case first so a
    # crash mid-emission leaves a red artifact, never nothing.
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="lp-interop--OPP--policies" tests="1" failures="1" skipped="0">\n  <testcase classname="interop.opp.policies.evidence-incomplete" name="EVIDENCE-INCOMPLETE: junit emission aborted" time="0">\n    <failure message="evidence-incomplete">skip-visibility JUnit emission did not complete</failure>\n  </testcase>\n</testsuite>\n' > "${_f}" || {
      printf '[%s] WARNING: could not write %s\n' "$(date -u +%FT%TZ)" "${_f}" >&2
      return 0
    }
    typeset _tmp=""
    _tmp="$(mktemp "${_f}.XXXXXX")" || return 0
    chmod 0644 "${_tmp}"
    typeset _n=${#skipPresentArr[@]}
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<testsuite name="lp-interop--OPP--policies" tests="%d" failures="%d" skipped="0">\n' "${_n}" "${_n}"
      printf '%s\n' "${skipPresentArr[@]}" | LC_ALL=C sort -t'|' -k1,1 | while IFS='|' read -r _p _present; do
        typeset _esc=''
        _esc="$(_skip_xml_escape "${_p}")"
        printf '  <testcase classname="lp-interop--OPP--policies" name="[sig-interop][Jira:INTEROP][Feature:OPP] %s skipped by SKIP_POLICIES" time="0">\n' "${_esc}"
        printf '    <failure message="policy skipped by SKIP_POLICIES">%s skipped by SKIP_POLICIES; state=skipped-configured; present in cluster: %s; see skip-policies.txt</failure>\n' "${_esc}" "${_present}"
        printf '  </testcase>\n'
      done
      printf '</testsuite>\n'
    } > "${_tmp}" || { rm -f "${_tmp}"; return 0; }
    # Checked invariant: parse and verify identity (counts AND the
    # testcase name sequence equals the sorted normalized list), then
    # atomically replace the pre-seed.
    if python3 - "${_tmp}" "${_n}" "${_f}" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET
path, n, final = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ts = ET.parse(path).getroot()
if ts.tag != "testsuite":
    sys.exit(1)
tcs = ts.findall("testcase")
if len(tcs) != n or int(ts.get("tests", -1)) != n or int(ts.get("failures", -1)) != n:
    sys.exit(1)
if sum(1 for tc in tcs if tc.find("failure") is not None) != n:
    sys.exit(1)
os.replace(path, final)
PY
    then
      printf '[%s] Wrote %d skip-visibility failure(s) to %s\n' \
        "$(date -u +%FT%TZ)" "${_n}" "${_f}"
    else
      rm -f "${_tmp}"
      printf '[%s] WARNING: JUNIT CONTRACT VIOLATION — skip-visibility artifact failed verification; pre-seed retained\n' \
        "$(date -u +%FT%TZ)" >&2
    fi
    return 0
  )
  _skip_junit_emit || printf '[%s] WARNING: skip-visibility JUnit emission degraded\n' "$(date -u +%FT%TZ)" >&2

  if (( ${#applyPoliciesArr[@]} > 0 )); then
    printf '[%s] Waiting for %d non-skipped polic(ies) to become Compliant…\n' \
      "$(date -u +%FT%TZ)" "${#applyPoliciesArr[@]}"
    if ! printf '%s\n' "${applyPoliciesArr[@]}" |
      xargs oc wait -n policies \
        --for jsonpath='{.status.compliant}'=Compliant \
        --timeout=40m; then
      : "Non-skipped policies failed to become compliant:"
      printf '%s\n' "${applyPoliciesArr[@]}"
      oc get policies -n policies --ignore-not-found -o yaml
      oc describe policies -n policies
      exit 1
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
    : "Policies failed to become compliant:"
    oc get policies -n policies --ignore-not-found
    oc get policies -n policies --ignore-not-found -o yaml
    oc describe policies -n policies
    exit 1
  fi
fi

true
