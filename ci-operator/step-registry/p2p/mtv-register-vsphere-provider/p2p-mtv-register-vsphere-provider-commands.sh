#!/bin/bash
#
# Register a VMware vSphere vCenter as an MTV Provider (type: vsphere) on the hub (CI step).
#
# Reads the vCenter host from SHARED_DIR (written by p2p-create-vsphere-test-vms) and vault
# credentials, then creates the Provider secret and Provider CR on the hub. Waits for the
# Provider inventory connection to reach Ready before returning.
#
# Vault credentials mounted at /var/run/vault/vsphere-ibmcloud-config/:
#   load-vsphere-env-config.sh — sets VCENTER_AUTH_PATH pointing to "user:password" file
#
# Inputs from SHARED_DIR:
#   vsphere-vcenter-host       — vCenter hostname (written by p2p-create-vsphere-test-vms)
#
# Note: uses set +x around credential handling — never logs vCenter password.
#

set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -r VSPHERE_ENV_SCRIPT=/var/run/vault/vsphere-ibmcloud-config/load-vsphere-env-config.sh

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# =====================
# Input validation
# =====================
[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]
[[ -f "${VSPHERE_ENV_SCRIPT}" ]]
[[ -f "${SHARED_DIR}/vsphere-vcenter-host" ]]

typeset vcenterHost
vcenterHost="$(< "${SHARED_DIR}/vsphere-vcenter-host")"
[[ -n "${vcenterHost}" ]]

# =====================
# Load vSphere vault config to get credential path
# =====================
# shellcheck disable=SC1090
source "${VSPHERE_ENV_SCRIPT}"
[[ -n "${VCENTER_AUTH_PATH:-}" ]]
[[ -f "${VCENTER_AUTH_PATH}" ]]

# =====================
# Get SSL thumbprint for Provider secret (disable xtrace)
# =====================
typeset thumbprintFile="${SHARED_DIR}/vsphere-thumbprint"
( set +x
  typeset thumbprint
  thumbprint="$(
      openssl s_client -connect "${vcenterHost}:443" </dev/null 2>/dev/null |
      openssl x509 -fingerprint -sha1 -noout 2>/dev/null |
      sed 's/.*Fingerprint=//'
  )" || true
  if [[ -n "${thumbprint}" ]]; then
      printf '%s' "${thumbprint}" > "${thumbprintFile}"
  else
      : "WARNING: could not fetch SSL thumbprint — will use insecureSkipVerify"
      printf '' > "${thumbprintFile}"
  fi
  true
)

# =====================
# Ensure MTV namespace exists
# =====================
oc get ns "${MTV_NAMESPACE}" 1>/dev/null

typeset secretName="${P2P_MTV_VSPHERE_PROVIDER_NAME}-secret"
typeset vcenterUrl="https://${vcenterHost}/sdk"

# =====================
# Create Provider secret (credentials — disable xtrace)
# =====================
# Uses process substitution so credentials are never in a shell variable that xtrace could log.
( set +x
  typeset vcenterUser vcenterPassword thumbprint
  vcenterUser="$(< "${VCENTER_AUTH_PATH}")"
  vcenterPassword="${vcenterUser#*:}"
  vcenterUser="${vcenterUser%%:*}"
  thumbprint="$(< "${thumbprintFile}")"

  if [[ -n "${thumbprint}" ]]; then
      oc -n "${MTV_NAMESPACE}" create secret generic "${secretName}" \
          --from-literal=user="${vcenterUser}" \
          --from-literal=password="${vcenterPassword}" \
          --from-literal=thumbprint="${thumbprint}" \
          --dry-run=client -o yaml --save-config | oc apply -f - 1>/dev/null
  else
      oc -n "${MTV_NAMESPACE}" create secret generic "${secretName}" \
          --from-literal=user="${vcenterUser}" \
          --from-literal=password="${vcenterPassword}" \
          --from-literal=insecureSkipVerify="true" \
          --dry-run=client -o yaml --save-config | oc apply -f - 1>/dev/null
  fi
  true
)

rm -f "${thumbprintFile}"

# =====================
# Create MTV vSphere Provider CR
# =====================
jq -n \
    --arg name   "${P2P_MTV_VSPHERE_PROVIDER_NAME}" \
    --arg ns     "${MTV_NAMESPACE}" \
    --arg url    "${vcenterUrl}" \
    --arg secret "${secretName}" \
    '{
        apiVersion: "forklift.konveyor.io/v1beta1",
        kind: "Provider",
        metadata: {name: $name, namespace: $ns},
        spec: {
            type: "vsphere",
            url: $url,
            secret: {name: $secret, namespace: $ns}
        }
    }' | {
    oc create -f - --dry-run=client -o yaml --save-config
} | oc apply -f -

# =====================
# Wait for Provider to be Ready (inventory connection established)
# =====================
oc -n "${MTV_NAMESPACE}" wait "provider/${P2P_MTV_VSPHERE_PROVIDER_NAME}" \
    --for=condition=Ready \
    --timeout="${P2P_MTV_VSPHERE_PROVIDER_READY_TIMEOUT}"

# =====================
# Artifacts
# =====================
oc get "provider/${P2P_MTV_VSPHERE_PROVIDER_NAME}" -n "${MTV_NAMESPACE}" -o yaml \
    > "${ARTIFACT_DIR}/mtv-vsphere-provider.yaml"

: "vSphere Provider ${P2P_MTV_VSPHERE_PROVIDER_NAME} ready — inventory URL: ${vcenterUrl}"
true
