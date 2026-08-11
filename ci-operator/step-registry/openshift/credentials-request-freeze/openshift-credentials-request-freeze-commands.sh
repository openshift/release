#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

fail() {
	echo "CredentialsRequest manifests in ${OPENSHIFT_LATEST_RELEASE_IMAGE} diverge from ${OPENSHIFT_FROZEN_RELEASE_IMAGE}.  This can cause trouble for Manual credentialsMode clusters ( https://docs.openshift.com/container-platform/4.9/installing/installing_aws/manually-creating-iam.html , and similarly for other clouds) perfoming patch updates (4.y.z -> 4.y.z'), because current Manual-mode guards only apply to minor updates (4.y.z -> 4.(y+1).z').  Find the team who introduced the change, and discuss whether the change is required (and acceptably documented in release notes for folks running Manual-mode clusters), in which case bump the oldest-supported-credentials-request config for the job to freeze on the new state ( grep for oldest-supported-credentials-request to find config locations like https://github.com/openshift/release/blob/0c7ecf26dfc04f9c64632e34d7a5ebcf42d69b99/ci-operator/config/openshift/release/openshift-release-master__nightly-4.10.yaml#L74-L77 ).  Until https://issues.redhat.com/browse/DPTP-2731 is implemented, you will need to wait for a new candidate payload that includes your changes to be available before bumping this value.  If you decide the change is not required, have the relevant team revert their change."
	return 1
}

cd /tmp
oc registry login
OPENSHIFT_LATEST_RELEASE_VERSION="$(oc adm release info -o 'jsonpath={.metadata.version}{"\n"}' "${OPENSHIFT_LATEST_RELEASE_IMAGE}")"
OPENSHIFT_FROZEN_RELEASE_VERSION="$(oc adm release info -o 'jsonpath={.metadata.version}{"\n"}' "${OPENSHIFT_FROZEN_RELEASE_IMAGE}")"
echo "Comparing ${OPENSHIFT_LATEST_RELEASE_VERSION} ( ${OPENSHIFT_LATEST_RELEASE_IMAGE} ) credentials requests against the expected requests from ${OPENSHIFT_FROZEN_RELEASE_VERSION} ( ${OPENSHIFT_FROZEN_RELEASE_IMAGE} )."


oc adm release extract --credentials-requests --cloud "${CLOUD:-}" --to frozen "${OPENSHIFT_FROZEN_RELEASE_IMAGE}"
oc adm release extract --credentials-requests --cloud "${CLOUD:-}" --to latest "${OPENSHIFT_LATEST_RELEASE_IMAGE}"
diff -ru frozen latest || fail
sha256sum frozen/* latest/*
