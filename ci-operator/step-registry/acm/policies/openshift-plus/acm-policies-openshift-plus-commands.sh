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

typeset -i pollDeadline=$((SECONDS + 600))
until (($(oc get policies -n policies -o name 2>/dev/null | wc -l))); do
  ((SECONDS > pollDeadline)) && { : "Error: no policies appeared after 10 minutes"; exit 1; }
  sleep 5
done

# Wait for Quay registry to be ready (checks operator-deployed Quay)
typeset -a quayNamespacesArr=(quay openshift-quay quay-enterprise)
typeset quayFound=false
for ns in "${quayNamespacesArr[@]}"; do
  if (($(oc get quayregistry -n "${ns}" -o name 2>/dev/null | wc -l))); then
    : "Found Quay Operator deployment in namespace ${ns}, waiting for ready condition"
    oc wait quayregistry --all -n "${ns}" \
      --for condition=Available=True \
      --timeout=10m || true
    quayFound=true
    break
  fi
done
[[ "${quayFound}" == "false" ]] && : "Warning: no QuayRegistry found in namespaces: ${quayNamespacesArr[*]}"

typeset -a secondaryPoliciesArr=(
  policy-acs
  policy-advanced-managed-cluster-status
  policy-hub-quay-bridge
  policy-quay-status
)

if [[ "${IGNORE_SECONDARY_POLICIES:-false}" == "true" ]]; then
  typeset criticalPolicies=''
  criticalPolicies=$(oc get policies -n policies -o name | grep -Ev "$(IFS='|'; echo "${secondaryPoliciesArr[*]}")" || true)

  if [[ -n "${criticalPolicies}" ]]; then
    {
      echo "${criticalPolicies}" |
      xargs oc wait -n policies \
        --for jsonpath='{.status.compliant}'=Compliant \
        --timeout=40m
    } || {
      : "Critical policies failed to become compliant:"
      oc get policies -n policies | grep -Ev "$(IFS='|'; echo "${secondaryPoliciesArr[*]}")" || true
      exit 1
    }
  else
    : "All policies are secondary (ignored), no critical policies to wait for"
  fi
else
  {
    oc wait policies --all -n policies \
      --for jsonpath='{.status.compliant}'=Compliant \
      --timeout=40m
  } || {
    : "Policies failed to become compliant:"
    oc get policies -n policies
    exit 1
  }
fi

true
