#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"
exec > >(tee "${ARTIFACT_DIR}/omr-v3-validation.log") 2>&1

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function validate_idms_mappings() {
    local idms_json="$1"
    local mirror_host="$2"
    local release_image="$3"
    local release_source="${release_image%@*}"
    local source
    local -a sources=(
        "${release_source}"
        quay.io/openshift-release-dev/ocp-v4.0-art-dev
    )

    if [[ "${release_source}" == "${release_image}" ]]; then
        echo "Release image does not contain a digest: ${release_image}"
        return 1
    fi

    for source in "${sources[@]}"; do
        if ! jq -e --arg source "${source}" --arg mirror "${mirror_host}/" '
          any(.items[].spec.imageDigestMirrors[]?;
            .source == $source and any(.mirrors[]?; startswith($mirror)))
        ' "${idms_json}" > /dev/null; then
            echo "IDMS does not map ${source} to ${mirror_host}."
            return 1
        fi
    done
}

required_files=(
    mirror_registry_url
    oc-mirror-signature-configmap.json
    omr_mirror_completed_at
    omr_mirror_repository
    omr_mirrored_cli_image
    bastion_public_address
    bastion_ssh_user
)
for name in "${required_files[@]}"; do
    if [[ ! -s "${SHARED_DIR}/${name}" ]]; then
        echo "Required shared file is missing or empty: ${name}"
        exit 1
    fi
done

signature_configmap="${SHARED_DIR}/oc-mirror-signature-configmap.json"
if ! jq -e '
  .apiVersion == "v1"
  and .kind == "ConfigMap"
  and .metadata.name == "mirrored-release-signatures"
  and .metadata.namespace == "openshift-config-managed"
  and (.binaryData | type == "object" and length > 0)
' "${signature_configmap}" > /dev/null; then
    echo "The generated oc-mirror release signature ConfigMap is invalid."
    exit 1
fi
oc apply -f "${signature_configmap}"

oc wait clusterversion/version --for=condition=Available --timeout=10m
oc get clusterversion version -o wide
oc get clusteroperators

degraded=$(oc get clusteroperators -o json | jq -r '
  [.items[] | select(any(.status.conditions[]?; .type == "Degraded" and .status == "True")) | .metadata.name]
  | join(" ")
')
if [[ -n "${degraded}" ]]; then
    echo "Degraded ClusterOperators: ${degraded}"
    exit 1
fi

oc wait nodes --all --for=condition=Ready --timeout=10m
oc get nodes -o wide

idms_json="${ARTIFACT_DIR}/image-digest-mirror-sets.json"
oc get imagedigestmirrorsets -o json > "${idms_json}"
mirror_host=$(<"${SHARED_DIR}/mirror_registry_url")
validate_idms_mappings \
    "${idms_json}" \
    "${mirror_host}" \
    "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and the current uid has no passwd entry."
        exit 1
    fi
fi

bastion_address=$(<"${SHARED_DIR}/bastion_public_address")
bastion_user=$(<"${SHARED_DIR}/bastion_ssh_user")
mirror_completed_at=$(<"${SHARED_DIR}/omr_mirror_completed_at")
mirror_repository=$(<"${SHARED_DIR}/omr_mirror_repository")
repository_path="${mirror_repository#*/}"
ssh_options=(
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
)
journal_file="${ARTIFACT_DIR}/quay-journal-after-mirror.log"
ssh "${ssh_options[@]}" "${bastion_user}@${bastion_address}" \
    "sudo journalctl -u quay.service --since '${mirror_completed_at}' --no-pager --output=short-iso" \
    > "${journal_file}"
if ! grep -F "/v2/${repository_path}/" "${journal_file}" > /dev/null; then
    echo "No OMR request for /v2/${repository_path}/ was recorded after mirror completion."
    exit 1
fi

smoke_namespace=quay-omr-v3-smoke
smoke_pod=omr-v3-mirrored-cli-smoke
smoke_image=$(<"${SHARED_DIR}/omr_mirrored_cli_image")
oc create namespace "${smoke_namespace}" \
    --dry-run=client -o yaml | oc apply -f -
trap 'oc delete namespace "${smoke_namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
oc -n "${smoke_namespace}" delete pod "${smoke_pod}" --ignore-not-found --wait=true
oc -n "${smoke_namespace}" run "${smoke_pod}" --image="${smoke_image}" --restart=Never \
    --command -- oc version --client=true
if ! oc -n "${smoke_namespace}" wait pod/"${smoke_pod}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m; then
    oc -n "${smoke_namespace}" describe pod "${smoke_pod}"
    oc -n "${smoke_namespace}" logs "${smoke_pod}" || true
    exit 1
fi
oc -n "${smoke_namespace}" get pod "${smoke_pod}" -o wide
oc -n "${smoke_namespace}" logs "${smoke_pod}" | tee "${ARTIFACT_DIR}/mirrored-cli-smoke.log"

echo "OMR v3 disconnected validation passed."
