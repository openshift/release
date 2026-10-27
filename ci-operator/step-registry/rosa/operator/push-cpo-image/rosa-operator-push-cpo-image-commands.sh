#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${*}\033[0m"
}

# Only mirror the CPO image when the job is testing an openshift/hypershift PR. Periodics, manual
# runs, and release-repo rehearsals must continue using the CPO from the OCP release payload.
if [[ -z "${JOB_SPEC:-}" ]]; then
  log "JOB_SPEC is unset; skipping CPO image mirror"
  exit 0
fi
HYPERSHIFT_PULL_NUMBER=$(echo "${JOB_SPEC}" | jq -r \
  '([.refs] + (.extra_refs // []) | map(select(.org=="openshift" and .repo=="hypershift") | (.pulls // [])[]) | first | .number) // empty')
if [[ -z "${HYPERSHIFT_PULL_NUMBER}" ]]; then
  log "No openshift/hypershift PR under test; skipping CPO image mirror"
  exit 0
fi

if [[ -z "${CPO_SRC_IMAGE:-}" ]]; then
  log "ERROR: CPO_SRC_IMAGE is required (the PR-built control plane image injected via dependencies)"
  exit 1
fi

CREDS_DIR="/var/run/quay-credentials"
USERNAME_FILE="${CREDS_DIR}/username"
CREDENTIAL_FILE="${CREDS_DIR}/credential"
if [[ ! -r "${USERNAME_FILE}" || ! -r "${CREDENTIAL_FILE}" ]]; then
  log "ERROR: Quay username or credential is not available in ${CREDS_DIR}"
  exit 1
fi

# Use one private auth file for both the CI source registry and the Quay destination. Disable
# tracing while reading and passing the Quay robot credential so it cannot be exposed in job logs.
CPO_AUTH_DIR="/tmp/rosa-cpo-auth"
install -d -m 0700 "${CPO_AUTH_DIR}"
export REGISTRY_AUTH_FILE="${CPO_AUTH_DIR}/auth.json"
oc registry login --to="${REGISTRY_AUTH_FILE}"

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USERNAME=$(tr -d '\r\n' < "${USERNAME_FILE}")
QUAY_CREDENTIAL=$(tr -d '\r\n' < "${CREDENTIAL_FILE}")
if [[ -z "${QUAY_USERNAME}" || -z "${QUAY_CREDENTIAL}" ]]; then
  log "ERROR: Quay username or credential is empty"
  unset QUAY_USERNAME QUAY_CREDENTIAL
  ${WAS_TRACING} && set -x
  exit 1
fi
oc registry login --registry=quay.io \
  --auth-basic="${QUAY_USERNAME}:${QUAY_CREDENTIAL}" \
  --to="${REGISTRY_AUTH_FILE}"
unset QUAY_USERNAME QUAY_CREDENTIAL
${WAS_TRACING} && set -x

TAG="pr-${HYPERSHIFT_PULL_NUMBER}-${BUILD_ID:-unknown}"
DEST="${CPO_QUAY_REPO}:${TAG}"

log "Mirroring PR control-plane-operator image"
log "  source: ${CPO_SRC_IMAGE}"
log "  destination: ${DEST}"
oc image mirror --registry-config="${REGISTRY_AUTH_FILE}" "${CPO_SRC_IMAGE}" "${DEST}"

# Record an immutable digest pullspec and verify it with the Quay credential. The repository is
# private; rosa-operator-override-cpo-image adds the same credential to the HostedCluster pull
# secret before applying the image annotation.
DIGEST=$(oc image info --registry-config="${REGISTRY_AUTH_FILE}" -o json "${DEST}" | jq -r '.digest // empty')
if [[ -z "${DIGEST}" ]]; then
  log "ERROR: Failed to resolve the mirrored CPO image digest"
  exit 1
fi
CPO_IMAGE_REF="${CPO_QUAY_REPO}@${DIGEST}"

echo "${CPO_IMAGE_REF}" > "${SHARED_DIR}/cpo-image"
log "CPO image mirrored and readable with the Quay credential: ${CPO_IMAGE_REF}"
