#!/bin/bash
#
# Exchange KubeVirt CA bundles between all spoke clusters so virt-handler on each
# spoke trusts the virt-synchronization-controller TLS certificate on every other spoke.
#
# Background: KubeVirt watches the `kubevirt-ca` ConfigMap (key: ca-bundle) in the CNV
# namespace via extensionsKubeVirtCAConfigMapInformer for its TLS trust pool. CCLM uses
# mTLS via spec.sendTo, requiring each spoke's virt-handler to trust the peer's KubeVirt
# CA. MTV 2.12.x does not inject the destination CA — this step provides that exchange.
#
set -euxo pipefail; shopt -s inherit_errexit

typeset -i spokeCount="${CNV_EXCHANGE_KUBEVIRT_CA__SPOKE_COUNT}"
typeset cnvNs="${CNV_EXCHANGE_KUBEVIRT_CA__CNV_NS}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeCasArr=()

CollectSpokeKubeconfigs() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kc="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        [[ -r "${kc}" ]]
        spokeKubeconfigsArr+=("${kc}")
    done
    true
}

# GetKubevirtCaBundle — read the raw ca-bundle PEM from a spoke's kubevirt-ca ConfigMap.
GetKubevirtCaBundle() {
    typeset kc="${1:?}"
    oc --kubeconfig="${kc}" get configmap kubevirt-ca \
        -n "${cnvNs}" \
        -o jsonpath='{.data.ca-bundle}'
}

# ExtractUniqueCerts — read PEM text from stdin, emit only unique certs (by SHA-256 fingerprint).
ExtractUniqueCerts() {
    typeset currentCert=""
    typeset -A seenArr=()

    while IFS= read -r line; do
        if [[ "${line}" == *"BEGIN CERTIFICATE"* ]]; then
            currentCert="${line}"
        elif [[ -n "${currentCert}" ]]; then
            currentCert+=$'\n'"${line}"
            if [[ "${line}" == *"END CERTIFICATE"* ]]; then
                typeset fp
                fp="$(printf '%s\n' "${currentCert}" \
                    | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
                if [[ -n "${fp}" && -z "${seenArr["${fp}"]+_}" ]]; then
                    seenArr["${fp}"]=1
                    printf '%s\n' "${currentCert}"
                fi
                currentCert=""
            fi
        fi
    done
    true
}

# PatchKubevirtCaBundle — idempotently apply a PEM bundle to a spoke's kubevirt-ca ConfigMap.
PatchKubevirtCaBundle() {
    typeset kc="${1:?}"
    typeset combinedPem="${2:?}"

    oc --kubeconfig="${kc}" patch configmap kubevirt-ca \
        -n "${cnvNs}" \
        --type merge \
        -p "$(jq -n --arg bundle "${combinedPem}" '{"data":{"ca-bundle":$bundle}}')" \
        1>/dev/null
}

CollectSpokeKubeconfigs

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    typeset ca
    ca="$(GetKubevirtCaBundle "${spokeKubeconfigsArr[i]}")"
    [[ -n "${ca}" ]]
    spokeCasArr+=("${ca}")
done

# Build a single combined PEM bundle of all unique spoke CAs, then apply to every spoke.
typeset combinedBundle
combinedBundle="$(
    for ((i = 0; i < spokeCount; i++)); do
        printf '%s\n' "${spokeCasArr[i]}"
    done | ExtractUniqueCerts
)"

typeset -i combinedCount
combinedCount="$(printf '%s\n' "${combinedBundle}" | grep -c 'BEGIN CERTIFICATE' || true)"
: "combined unique KubeVirt CA count: ${combinedCount}"
((combinedCount >= spokeCount))

for ((i = 0; i < spokeCount; i++)); do
    PatchKubevirtCaBundle "${spokeKubeconfigsArr[i]}" "${combinedBundle}"

    typeset newCount
    newCount="$(GetKubevirtCaBundle "${spokeKubeconfigsArr[i]}" \
        | grep -c 'BEGIN CERTIFICATE' || true)"
    : "spoke $((i+1)): kubevirt-ca now has ${newCount} cert(s)"
    ((newCount >= spokeCount))
done

if [[ -n "${ARTIFACT_DIR}" ]]; then
    mkdir -p "${ARTIFACT_DIR}"
    for ((i = 0; i < spokeCount; i++)); do
        oc --kubeconfig="${spokeKubeconfigsArr[i]}" get configmap kubevirt-ca \
            -n "${cnvNs}" \
            -o jsonpath='{.data.ca-bundle}' \
            | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
            | openssl pkcs7 -print_certs -noout 2>/dev/null \
            > "${ARTIFACT_DIR}/spoke-$((i+1))-kubevirt-ca-subjects.txt" || true
    done
fi

true
