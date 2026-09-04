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

if [[ "${IGNORE_SECONDARY_POLICIES}" == "true" ]]; then
  typeset criticalPolicies=''
  criticalPolicies=$(oc get policies -n policies -o name | sed -E "/$(IFS='|'; echo "${secondaryPoliciesArr[*]}")/d")

  if [[ -n "${criticalPolicies}" ]]; then
    if ! echo "${criticalPolicies}" |
      xargs oc wait -n policies \
        --for jsonpath='{.status.compliant}'=Compliant \
        --timeout=40m; then
      : "Critical policies failed to become compliant:"
      oc get policies -n policies --ignore-not-found | sed -E "/$(IFS='|'; echo "${secondaryPoliciesArr[*]}")/d"
      oc get policies -n policies --ignore-not-found -o yaml
      oc describe policies --all -n policies
      exit 1
    fi
  else
    : "All policies are secondary (ignored), no critical policies to wait for"
  fi
else
  if ! oc wait policies --all -n policies \
    --for jsonpath='{.status.compliant}'=Compliant \
    --timeout=40m; then
    : "Policies failed to become compliant:"
    oc get policies -n policies --ignore-not-found
    oc get policies -n policies --ignore-not-found -o yaml
    oc describe policies --all -n policies
    exit 1
  fi
fi

true
