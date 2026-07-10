#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"
exec > >(tee "${ARTIFACT_DIR}/omr-3-validation.log") 2>&1

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

required_files=(
    mirror_registry_url
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
for source in \
    quay.io/openshift-release-dev/ocp-release \
    quay.io/openshift-release-dev/ocp-v4.0-art-dev; do
    if ! jq -e --arg source "${source}" --arg mirror "${mirror_host}/" '
      any(.items[].spec.imageDigestMirrors[]?;
        .source == $source and any(.mirrors[]?; startswith($mirror)))
    ' "${idms_json}" > /dev/null; then
        echo "IDMS does not map ${source} to ${mirror_host}."
        exit 1
    fi
done

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

smoke_pod=omr-3-mirrored-cli-smoke
smoke_image=$(<"${SHARED_DIR}/omr_mirrored_cli_image")
oc delete pod "${smoke_pod}" --ignore-not-found --wait=true
trap 'oc delete pod "${smoke_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
oc run "${smoke_pod}" --image="${smoke_image}" --restart=Never \
    --command -- oc version --client=true
if ! oc wait pod/"${smoke_pod}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m; then
    oc describe pod "${smoke_pod}"
    oc logs "${smoke_pod}" || true
    exit 1
fi
oc get pod "${smoke_pod}" -o wide
oc logs "${smoke_pod}" | tee "${ARTIFACT_DIR}/mirrored-cli-smoke.log"

echo "OMR 3 disconnected validation passed."
