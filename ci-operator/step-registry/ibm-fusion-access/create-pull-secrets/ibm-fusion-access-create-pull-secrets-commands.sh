#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

CreateRegistryAuth() {
  typeset ns="${1}"; (($#)) && shift
  typeset name="${1}"; (($#)) && shift
  typeset regHost="${1}"; (($#)) && shift
  typeset regUsr="${1}"; (($#)) && shift
  typeset regPwdFile="${1}"; (($#)) && shift

  oc -n "${ns}" create secret generic "${name}" \
    --from-file=.dockerconfigjson=<(
      jq -cnr \
        --arg host "${regHost}" \
        --arg usr "${regUsr}" \
        --rawfile pwd "${regPwdFile}" \
        '{auths: {($host): {auth: ("\($usr):\($pwd | rtrimstr("\n"))" | @base64), email: ""}}}'
    ) \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml --save-config | oc apply -f -

  true
}

CreateRegistryAuthFromFile() {
  typeset ns="${1}"; (($#)) && shift
  typeset name="${1}"; (($#)) && shift
  typeset regHost="${1}"; (($#)) && shift
  typeset authFile="${1}"; (($#)) && shift

  oc -n "${ns}" create secret generic "${name}" \
    --from-file=.dockerconfigjson=<(
      jq -cnr \
        --arg host "${regHost}" \
        --rawfile auth "${authFile}" \
        '{auths: {($host): {auth: ($auth | rtrimstr("\n")), email: ""}}}'
    ) \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml --save-config | oc apply -f -

  true
}

PatchDefaultSAImagePullSecrets() {
  if oc get secret fusion-pullsecret-extra -n "${FA__NAMESPACE}" >/dev/null; then
    oc patch serviceaccount default -n "${FA__NAMESPACE}" \
      -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"},{"name":"fusion-pullsecret-extra"}]}'
  else
    oc patch serviceaccount default -n "${FA__NAMESPACE}" \
      -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
  fi

  true
}

ibmEntitlementKeyPath="/var/run/secrets/ibm-entitlement-key"

CreateRegistryAuth "${FA__NAMESPACE}" "fusion-pullsecret" "${FA__IBM_REGISTRY}" "cp" "${ibmEntitlementKeyPath}"
oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n "${FA__NAMESPACE}" --timeout=60s

CreateRegistryAuth "${FA__NAMESPACE}" "ibm-entitlement-key" "${FA__IBM_REGISTRY}" "cp" "${ibmEntitlementKeyPath}"
oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n "${FA__NAMESPACE}" --timeout=60s

oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  jq --rawfile pwd "${ibmEntitlementKeyPath}" \
    --arg host "${FA__IBM_REGISTRY}" \
    '.auths[$host] = {auth: ("cp:\($pwd | rtrimstr("\n"))" | @base64), email: ""}' | \
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin

for ns in "${FA__SCALE__NAMESPACE}" "${FA__SCALE__DNS_NAMESPACE}" "${FA__SCALE__CSI_NAMESPACE}" "${FA__SCALE__OPERATOR_NAMESPACE}"; do
  if oc get namespace "${ns}" >/dev/null; then
    CreateRegistryAuth "${ns}" "ibm-entitlement-key" "${FA__IBM_REGISTRY}" "cp" "${ibmEntitlementKeyPath}"
    oc wait --for=jsonpath='{.metadata.name}'=ibm-entitlement-key secret/ibm-entitlement-key -n "${ns}" --timeout=60s
  fi
done

if [[ -f /var/run/secrets/fusion-pullsecret-extra ]]; then
  CreateRegistryAuthFromFile "${FA__NAMESPACE}" "fusion-pullsecret-extra" "quay.io/openshift-storage-scale" "/var/run/secrets/fusion-pullsecret-extra"
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret-extra secret/fusion-pullsecret-extra -n "${FA__NAMESPACE}" --timeout=60s
fi

PatchDefaultSAImagePullSecrets

true
