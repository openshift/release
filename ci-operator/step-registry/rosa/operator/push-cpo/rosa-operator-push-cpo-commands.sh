#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Mirrors the PR-built control-plane-operator (CPO) image to a public quay.io/rrp-dev-ci repository so
# the hosted control plane can pull it with the cluster's own pull secret. This avoids merging CI
# registry credentials into the HostedCluster pull secret, which the ACM work agent can resync and
# revert mid-run, breaking later CPO pod pulls (ROSAENG-74212 review feedback). The pushed pullspec is
# written to ${SHARED_DIR}/cpo-image for rosa-operator-annotate-cpo to stamp on the HostedCluster.

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${*}\033[0m"
}

# Only mirror when a PR is under test. Without one (periodic, gangway, or manual runs) the CPO shipped
# in the release payload is the one we want to test, so there is nothing to push. /payload-job runs are
# periodics, so JOB_TYPE does not distinguish them; inspect JOB_SPEC for pull refs instead.
if [[ -z "${JOB_SPEC:-}" ]]; then
  log "JOB_SPEC is unset; assuming no PR under test, skipping CPO image mirror"
  exit 0
fi
PULLS=$(echo "${JOB_SPEC}" | jq -r '[.refs] + (.extra_refs // []) | map(select(. != null) | (.pulls // []) | length) | add // 0')
if (( PULLS == 0 )); then
  log "No PR under test; skipping CPO image mirror"
  exit 0
fi

if [[ -z "${CPO_SRC_IMAGE:-}" ]]; then
  log "ERROR: CPO_SRC_IMAGE is required (the PR-built control plane image, injected via dependencies)"
  exit 1
fi

AUTHFILE="/var/run/quay-push-credentials/.dockerconfigjson"
if [[ ! -r "${AUTHFILE}" ]]; then
  log "ERROR: ${AUTHFILE} not found or not readable (rrp-dev-ci-quay push credentials not mounted)"
  exit 1
fi

# Build a docker config that can both push to quay (from the mounted credentials) and pull the source
# image from the CI registry (added by oc registry login).
export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${HOME}/.docker" "${XDG_RUNTIME_DIR}/containers"
cp "${AUTHFILE}" "${HOME}/.docker/config.json"
oc registry login

TAG="ci-${PULL_NUMBER:-0}-${BUILD_ID:-unknown}"
DEST="${CPO_QUAY_REPO}:${TAG}"

log "Mirroring PR control-plane-operator image to public quay"
log "  source: ${CPO_SRC_IMAGE}"
log "  dest:   ${DEST}"
oc image mirror "${CPO_SRC_IMAGE}" "${DEST}"

# Record the public pullspec for rosa-operator-annotate-cpo.
echo "${DEST}" > "${SHARED_DIR}/cpo-image"
log "CPO image mirrored: ${DEST}"
