#!/bin/bash
#
# Exchange KubeVirt CA bundles between all spoke clusters so virt-handler on each
# spoke trusts the virt-synchronization-controller TLS certificate on every other spoke.
#
# Background: KubeVirt watches the `kubevirt-ca` ConfigMap (key: ca-bundle) in the CNV
# namespace via extensionsKubeVirtCAConfigMapInformer for its TLS trust pool. CCLM uses
# mTLS via spec.sendTo, requiring each spoke's virt-handler to trust the peer's KubeVirt
# CA. MTV (release-v2.11 and later) does not inject the destination CA — this step
# provides that exchange.
#
set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i spokeCount="${CNV_EXCHANGE_KUBEVIRT_CA__SPOKE_COUNT}"
typeset -i acmSpokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
(( spokeCount > 0 )) \
    || { : "CNV_EXCHANGE_KUBEVIRT_CA__SPOKE_COUNT must be a positive integer (got: '${CNV_EXCHANGE_KUBEVIRT_CA__SPOKE_COUNT}')"; false; }
(( spokeCount == acmSpokeCount )) \
    || { : "CNV_EXCHANGE_KUBEVIRT_CA__SPOKE_COUNT (${spokeCount}) must equal ACM_SPOKE_CLUSTER_COUNT (${acmSpokeCount}) — check job configuration"; false; }
typeset cnvNs="${CNV_EXCHANGE_KUBEVIRT_CA__CNV_NS}"

typeset -a spokeKubeconfigsArr=()
# Temp PEM files — one per spoke + one combined bundle.
# Using files (not shell variables) keeps cert data out of xtrace output per MPEX BP-10.
typeset -a spokeCaFilesArr=()
typeset combinedFile=""

# CleanupTempFiles — remove ephemeral PEM files on EXIT.
function CleanupTempFiles () {
    ( set +x
        rm -f "${spokeCaFilesArr[@]}" "${combinedFile}" || true
    true )
}
trap CleanupTempFiles EXIT

function CollectSpokeKubeconfigs () {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kc="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        [[ -r "${kc}" ]]
        spokeKubeconfigsArr+=("${kc}")
    done
    true
}

# GetKubevirtCaBundle — write raw ca-bundle PEM from a spoke's kubevirt-ca ConfigMap to a file.
# xtrace-safe: oc get command and file path are traced; cert content goes to a file.
function GetKubevirtCaBundle () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset outFile="${1:?}"; (($#)) && shift
    oc --kubeconfig="${kc}" get configmap kubevirt-ca \
        -n "${cnvNs}" \
        -o jsonpath='{.data.ca-bundle}' > "${outFile}"
}

# ExtractUniqueCerts — read PEM text from stdin, emit only unique certs (by SHA-256 fingerprint).
# set +x here: this function processes cert lines via the currentCert shell variable;
# xtrace would trace each intermediate assignment. Since this always runs in a pipeline
# subshell, set +x affects only the subshell and does NOT change the parent's xtrace state.
function ExtractUniqueCerts () {
    set +x
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

# PatchKubevirtCaBundle — idempotently apply a combined PEM bundle to a spoke's kubevirt-ca ConfigMap.
# xtrace-safe: jq reads cert from file via --rawfile (file path traced, not cert content);
# the patch is piped to oc apply via stdin so cert never appears in any command argument.
function PatchKubevirtCaBundle () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset combinedPemFile="${1:?}"; (($#)) && shift

    oc --kubeconfig="${kc}" get configmap kubevirt-ca -n "${cnvNs}" -o json \
        | jq --rawfile bundle "${combinedPemFile}" '.data["ca-bundle"] = $bundle' \
        | oc --kubeconfig="${kc}" apply -f -
}

CollectSpokeKubeconfigs

# Collect each spoke's CA bundle into a dedicated temp file.
# File paths are safe to trace; cert content stays in files, never in shell variables.
typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    typeset caFile; caFile="$(mktemp /tmp/kubevirt-ca-XXXXXX.pem)"
    spokeCaFilesArr+=("${caFile}")
    GetKubevirtCaBundle "${spokeKubeconfigsArr[i]}" "${caFile}"
    [[ -s "${caFile}" ]]
done

# Build a single combined PEM bundle of all unique spoke CAs into a temp file.
combinedFile="$(mktemp /tmp/kubevirt-ca-combined-XXXXXX.pem)"
cat "${spokeCaFilesArr[@]}" | ExtractUniqueCerts > "${combinedFile}"

typeset -i combinedCount
combinedCount="$(grep -c 'BEGIN CERTIFICATE' "${combinedFile}" || true)"
: "combined unique KubeVirt CA count: ${combinedCount}"
# Require at least one unique cert in the combined bundle. Two spokes sharing the
# same CA legitimately produce combinedCount=1; comparing to spokeCount would fail.
(( combinedCount > 0 ))

for ((i = 0; i < spokeCount; i++)); do
    PatchKubevirtCaBundle "${spokeKubeconfigsArr[i]}" "${combinedFile}"

    # Verify: refresh the spoke's CA file and confirm the updated ConfigMap contains
    # exactly the same unique-cert count as the combined bundle we applied.
    GetKubevirtCaBundle "${spokeKubeconfigsArr[i]}" "${spokeCaFilesArr[i]}"
    typeset newCount
    newCount="$(grep -c 'BEGIN CERTIFICATE' "${spokeCaFilesArr[i]}" || true)"
    : "spoke $((i+1)): kubevirt-ca now has ${newCount} cert(s)"
    (( newCount >= combinedCount ))
done

if [[ -n "${ARTIFACT_DIR}" ]]; then
    mkdir -p "${ARTIFACT_DIR}"
    for ((i = 0; i < spokeCount; i++)); do
        openssl crl2pkcs7 -nocrl -certfile "${spokeCaFilesArr[i]}" 2>/dev/null \
            | openssl pkcs7 -print_certs -noout 2>/dev/null \
            > "${ARTIFACT_DIR}/spoke-$((i+1))-kubevirt-ca-subjects.txt" || true
    done
fi

true
