#!/bin/bash
set -euo pipefail

# Destroy the second IPI cluster provisioned by quay-georep-provision-cluster-b.
# Uses metadata.json (small, fits in SHARED_DIR) and re-extracts the installer
# from the release image. This script does not enable set -x to avoid leaking
# credentials.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-georep-deprovision-cluster-b"
mkdir -p "${ARTIFACT_DIR}"

if [[ ! -s "${SHARED_DIR}/cluster-b-metadata.json" ]]; then
    echo "No cluster B metadata found in SHARED_DIR; skipping cleanup." >&2
    exit 0
fi

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"

INSTALL_DIR="$(mktemp -d)"
cp "${SHARED_DIR}/cluster-b-metadata.json" "${INSTALL_DIR}/metadata.json"

CLUSTER_NAME="$(cat "${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_NAME" 2>/dev/null || echo "unknown")"
echo "Destroying cluster B '${CLUSTER_NAME}'..." >&2

RELEASE_IMAGE="$(cat "${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_RELEASE_IMAGE" 2>/dev/null || echo "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}")"
if [[ -z "${RELEASE_IMAGE}" ]]; then
    echo "ERROR: no release image available to extract openshift-install" >&2
    exit 1
fi

echo "Extracting openshift-install from release image..." >&2
oc adm release extract -a "${PULL_SECRET}" "${RELEASE_IMAGE}" \
    --command=openshift-install --to="${INSTALL_DIR}"
INSTALLER="${INSTALL_DIR}/openshift-install"
chmod +x "${INSTALLER}"

destroy_rc=1
for attempt in 1 2 3; do
    echo "openshift-install destroy cluster attempt ${attempt}/3 ..." >&2
    destroy_rc=0
    "${INSTALLER}" destroy cluster --dir="${INSTALL_DIR}" --log-level=info 2>&1 | tee "${ARTIFACT_DIR}/destroy-attempt-${attempt}.log" || destroy_rc=$?
    [[ "${destroy_rc}" -eq 0 ]] && break
    echo "destroy attempt ${attempt} failed (rc=${destroy_rc})" >&2
    sleep 30
done

if [[ "${destroy_rc}" -ne 0 ]]; then
    echo "WARNING: cluster B destroy failed after 3 attempts (rc=${destroy_rc}). Resources may be leaked." >&2
fi
