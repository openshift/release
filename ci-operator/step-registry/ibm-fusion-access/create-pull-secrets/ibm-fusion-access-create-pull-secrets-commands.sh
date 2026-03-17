#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

function CreateRegistryAuth () {
  typeset ns="${1}"; (($#)) && shift
  typeset name="${1}"; (($#)) && shift
  typeset regHost="${1}"; (($#)) && shift
  typeset regUsr="${1}"; (($#)) && shift
  typeset regPwdFile="${1}"; (($#)) && shift

  oc -n "${ns}" create secret generic "${name}" \
    --from-file=.dockerconfigjson=<(
      set +x
      jq -cnr \
        --arg host "${regHost}" \
        --arg usr "${regUsr}" \
        --rawfile pwd "${regPwdFile}" \
        '{auths: {($host): {auth: ("\($usr):\($pwd | rtrimstr("\n"))" | @base64), email: ""}}}'
    ) \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o json --save-config | oc apply -f -

  true
}

function CreateRegistryAuthFromFile () {
  typeset ns="${1}"; (($#)) && shift
  typeset name="${1}"; (($#)) && shift
  typeset regHost="${1}"; (($#)) && shift
  typeset b64AuthFile="${1}"; (($#)) && shift

  oc -n "${ns}" create secret generic "${name}" \
    --from-file=.dockerconfigjson=<(
      set +x
      jq -cnr \
        --arg host "${regHost}" \
        --rawfile auth "${b64AuthFile}" \
        '{auths: {($host): {auth: ($auth | rtrimstr("\n")), email: ""}}}'
    ) \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o json --save-config | oc apply -f -

  true
}

function PatchDefaultSAImagePullSecrets () {
  if oc get secret fusion-pullsecret-extra -n "${FA__NAMESPACE}" -o name; then
    oc patch serviceaccount default -n "${FA__NAMESPACE}" \
      -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"},{"name":"fusion-pullsecret-extra"}]}'
  else
    oc patch serviceaccount default -n "${FA__NAMESPACE}" \
      -p '{"imagePullSecrets":[{"name":"fusion-pullsecret"}]}'
  fi

  true
}

typeset ibmEntitlementKeyPath="/var/run/secrets/ibm-entitlement-key"

CreateRegistryAuth "${FA__NAMESPACE}" "fusion-pullsecret" "${FA__IBM_REGISTRY}" "cp" "${ibmEntitlementKeyPath}"
CreateRegistryAuth "${FA__NAMESPACE}" "ibm-entitlement-key" "${FA__IBM_REGISTRY}" "cp" "${ibmEntitlementKeyPath}"

oc get secret pull-secret -n openshift-config -o json | jq -r '.data[".dockerconfigjson"]' | base64 -d | \
  jq --rawfile pwd "${ibmEntitlementKeyPath}" \
    --arg host "${FA__IBM_REGISTRY}" \
    '.auths[$host] = {auth: ("cp:\($pwd | rtrimstr("\n"))" | @base64), email: ""}' | \
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin

for ns in "${FA__SCALE__NAMESPACE}" "${FA__SCALE__DNS_NAMESPACE}" "${FA__SCALE__CSI_NAMESPACE}" "${FA__SCALE__OPERATOR_NAMESPACE}"; do
  if oc get namespace "${ns}" -o name; then
    CreateRegistryAuth "${ns}" "ibm-entitlement-key" "${FA__IBM_REGISTRY}" "cp" "${ibmEntitlementKeyPath}"
  fi
done

if [[ -f /var/run/secrets/fusion-pullsecret-extra ]]; then
  CreateRegistryAuthFromFile "${FA__NAMESPACE}" "fusion-pullsecret-extra" "quay.io/openshift-storage-scale" "/var/run/secrets/fusion-pullsecret-extra"
fi

PatchDefaultSAImagePullSecrets

true
