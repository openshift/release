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
echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus

# openshift-plus generates ~25 policies; require 4+ before oc wait to avoid
# racing the GitOps Subscription propagation (stolostron/policy-collection#174)
typeset -i expectedMinPolicies=4
typeset -i pollDeadline=$((SECONDS + 600))
until (( $(oc get policies -n policies -o name 2>/dev/null | wc -l) >= expectedMinPolicies )); do
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
  if (($(oc get quayregistry -n "${ns}" -o name 2>/dev/null | wc -l))); then
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

# Override-aware secondary policies list
if [[ -n "${SECONDARY_POLICIES_OVERRIDE:-}" ]]; then
  read -ra secondaryPoliciesArr <<< "${SECONDARY_POLICIES_OVERRIDE}"
else
  typeset -a secondaryPoliciesArr=(
    policy-acs
    policy-acs-monitor-certs
    policy-acs-operator-central
    policy-acs-sync-resources
    policy-advanced-managed-cluster-security
    policy-advanced-managed-cluster-status
    policy-compliance-operator-install
    policy-config-quay
    policy-hub-quay-bridge
    policy-install-quay
    policy-observability-operator
    policy-observability-storage
    policy-observability-storage-status
    policy-odf
    policy-odf-cluster
    policy-odf-noobaa
    policy-odf-status
    policy-quay-bridge
    policy-quay-status
  )
fi

# Helper: escape XML special characters
xml_escape() {
  typeset s="${1//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "${s}"
}

# Helper: generate JUnit XML for policy compliance results
# Args: $1=output_file $2=critical_names (newline-delimited, "" if none)
#        $3=skipped_names (newline-delimited, "" if none) $4=critical_failed (true|false)
write_junit_xml() {
  typeset junit_file="$1" critical_str="$2" skipped_str="$3" critical_failed="${4:-false}"
  typeset -a crit_arr=() skip_arr=()

  if [[ -n "${critical_str}" ]]; then
    while IFS= read -r _n; do
      [[ -n "${_n}" ]] && crit_arr+=("${_n}")
    done <<< "${critical_str}"
  fi
  if [[ -n "${skipped_str}" ]]; then
    while IFS= read -r _n; do
      [[ -n "${_n}" ]] && skip_arr+=("${_n}")
    done <<< "${skipped_str}"
  fi

  typeset -i tests=$(( ${#crit_arr[@]} + ${#skip_arr[@]} )) failures=0 skips=${#skip_arr[@]}
  [[ "${critical_failed}" == "true" ]] && failures=${#crit_arr[@]}

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="openshift-plus-policy-compliance" tests="%d" failures="%d" skipped="%d">\n' \
      "${tests}" "${failures}" "${skips}"

    typeset _p _esc
    if (( ${#skip_arr[@]} > 0 )); then
      for _p in "${skip_arr[@]}"; do
        _esc=$(xml_escape "${_p}")
        printf '  <testcase name="%s" classname="openshift-plus.secondary">\n' "${_esc}"
        printf '    <skipped message="Secondary policy ignored (IGNORE_SECONDARY_POLICIES=true)"/>\n'
        printf '  </testcase>\n'
      done
    fi

    if (( ${#crit_arr[@]} > 0 )); then
      for _p in "${crit_arr[@]}"; do
        _esc=$(xml_escape "${_p}")
        if [[ "${critical_failed}" == "true" ]]; then
          printf '  <testcase name="%s" classname="openshift-plus.critical">\n' "${_esc}"
          printf '    <failure message="Policy did not become Compliant within timeout"/>\n'
          printf '  </testcase>\n'
        else
          printf '  <testcase name="%s" classname="openshift-plus.critical"/>\n' "${_esc}"
        fi
      done
    fi

    printf '</testsuite>\n'
  } > "${junit_file}"
}

if [[ "${IGNORE_SECONDARY_POLICIES}" == "true" ]]; then
  # Get all deployed policy names
  typeset -a allPolicyNames=()
  while IFS= read -r pname; do
    [[ -n "${pname}" ]] && allPolicyNames+=("${pname}")
  done < <(oc get policies -n policies -o name | sed 's|^.*/||')

  # Classify into critical vs secondary
  typeset -a criticalNames=() skippedNames=()
  typeset _pol _sec _isSecondary
  for _pol in "${allPolicyNames[@]}"; do
    _isSecondary=false
    for _sec in "${secondaryPoliciesArr[@]}"; do
      if [[ "${_pol}" == "${_sec}" ]]; then
        _isSecondary=true
        break
      fi
    done
    if [[ "${_isSecondary}" == "true" ]]; then
      skippedNames+=("${_pol}")
    else
      criticalNames+=("${_pol}")
    fi
  done

  typeset -i totalCount=${#allPolicyNames[@]}
  typeset -i criticalCount=${#criticalNames[@]}
  typeset -i skippedCount=${#skippedNames[@]}
  typeset -i skipRatio=0
  if (( totalCount > 0 )); then
    skipRatio=$(( skippedCount * 100 / totalCount ))
  fi

  echo "Policy classification: ${totalCount} total, ${criticalCount} critical, ${skippedCount} secondary (skipped)"
  echo "Skip ratio: ${skipRatio}% of policies are secondary"
  if (( skippedCount > 0 )); then
    echo "Skipped secondary policies: ${skippedNames[*]}"
  fi
  if (( criticalCount > 0 )); then
    echo "Critical policies to validate: ${criticalNames[*]}"
  fi

  # Generate skip manifest JSON to SHARED_DIR
  {
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "ignore_secondary_policies": true,\n'
    printf '  "total_count": %d,\n' "${totalCount}"
    printf '  "critical_count": %d,\n' "${criticalCount}"
    printf '  "skipped_count": %d,\n' "${skippedCount}"
    printf '  "skip_ratio_pct": %d,\n' "${skipRatio}"
    printf '  "skipped_policies": ['
    typeset -i _i
    for (( _i=0; _i<skippedCount; _i++ )); do
      (( _i > 0 )) && printf ','
      printf '"%s"' "${skippedNames[_i]}"
    done
    printf '],\n'
    printf '  "critical_policies": ['
    for (( _i=0; _i<criticalCount; _i++ )); do
      (( _i > 0 )) && printf ','
      printf '"%s"' "${criticalNames[_i]}"
    done
    printf ']\n'
    printf '}\n'
  } > "${SHARED_DIR}/skipped-policies.json"

  if (( criticalCount > 0 )); then
    # Build resource names for oc wait
    typeset -a waitResources=()
    for _pol in "${criticalNames[@]}"; do
      waitResources+=("policy/${_pol}")
    done

    set +e
    oc wait -n policies \
      --for jsonpath='{.status.compliant}'=Compliant \
      --timeout=40m \
      "${waitResources[@]}"
    typeset -i waitResult=$?
    set -e

    # Generate JUnit XML based on wait outcome
    typeset criticalStr="" skippedStr=""
    criticalStr=$(printf '%s\n' "${criticalNames[@]}")
    if (( skippedCount > 0 )); then
      skippedStr=$(printf '%s\n' "${skippedNames[@]}")
    fi

    if (( waitResult != 0 )); then
      write_junit_xml "${ARTIFACT_DIR}/junit_policy_compliance.xml" \
        "${criticalStr}" "${skippedStr}" "true"
      echo "Critical policies failed to become compliant:"
      oc get policies -n policies --ignore-not-found | \
        sed -E "/$(IFS='|'; echo "${secondaryPoliciesArr[*]}")/d"
      oc get policies -n policies --ignore-not-found -o yaml
      oc describe policies --all -n policies
      exit 1
    fi

    write_junit_xml "${ARTIFACT_DIR}/junit_policy_compliance.xml" \
      "${criticalStr}" "${skippedStr}" "false"
  else
    echo "WARN: All policies are secondary (ignored), no critical policies to wait for"
    typeset skippedStr=""
    if (( skippedCount > 0 )); then
      skippedStr=$(printf '%s\n' "${skippedNames[@]}")
    fi
    write_junit_xml "${ARTIFACT_DIR}/junit_policy_compliance.xml" \
      "" "${skippedStr}" "false"
  fi
else
  # Normal path: wait for all policies
  typeset -a allPolicyNames=()
  while IFS= read -r pname; do
    [[ -n "${pname}" ]] && allPolicyNames+=("${pname}")
  done < <(oc get policies -n policies -o name | sed 's|^.*/||')

  set +e
  oc wait policies --all -n policies \
    --for jsonpath='{.status.compliant}'=Compliant \
    --timeout=40m
  typeset -i waitResult=$?
  set -e

  typeset allStr=""
  if (( ${#allPolicyNames[@]} > 0 )); then
    allStr=$(printf '%s\n' "${allPolicyNames[@]}")
  fi

  if (( waitResult != 0 )); then
    write_junit_xml "${ARTIFACT_DIR}/junit_policy_compliance.xml" \
      "${allStr}" "" "true"
    echo "Policies failed to become compliant:"
    oc get policies -n policies --ignore-not-found
    oc get policies -n policies --ignore-not-found -o yaml
    oc describe policies --all -n policies
    exit 1
  fi

  write_junit_xml "${ARTIFACT_DIR}/junit_policy_compliance.xml" \
    "${allStr}" "" "false"
fi

true
