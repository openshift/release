#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Dev-scripts (baremetalds) clusters cannot always pull the scanner image
# straight from the build farm registry: ipv6-only clusters have no IPv4
# route out, so the scanner pod sits in ImagePullBackOff forever. Mirror
# the image into the local registry on the provisioning host instead, the
# same way baremetalds-e2e mirrors the e2e test images, and publish the
# mirrored pull spec for tls-scanner-run via ${SHARED_DIR}.
if [[ ! -f "${SHARED_DIR}/ds-vars.conf" || ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
    echo "Not a dev-scripts cluster (no ds-vars.conf/packet-conf.sh in SHARED_DIR) - nothing to mirror."
    exit 0
fi

# The provisioning host's pull secret has no credentials for this job's
# build farm namespace, so allow anonymous pulls from it (same approach
# as baremetalds-e2e-test). Unset KUBECONFIG to talk to the build farm,
# not the cluster under test.
echo "Granting anonymous image pull access on the build farm namespace..."
KUBECONFIG_BAK="${KUBECONFIG:-}"
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
if [[ -n "${KUBECONFIG_BAK}" ]]; then
    export KUBECONFIG="${KUBECONFIG_BAK}"
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/ds-vars.conf"

MIRROR_REPO="${DS_REGISTRY}/localimages/local-tls-scanner"
DIGEST="${PULL_SPEC_TLS_SCANNER_TOOL##*@}"
if [[ "${DIGEST}" == "${PULL_SPEC_TLS_SCANNER_TOOL}" ]]; then
    echo "Scanner pull spec is not digest-based, cannot mirror: ${PULL_SPEC_TLS_SCANNER_TOOL}"
    exit 1
fi

echo "Mirroring ${PULL_SPEC_TLS_SCANNER_TOOL} to ${MIRROR_REPO}"
# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -x - << EOF
set -o pipefail
for attempt in 1 2 3; do
    if oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json --keep-manifest-list \
        "${PULL_SPEC_TLS_SCANNER_TOOL}" "${MIRROR_REPO}:scanner"; then
        exit 0
    fi
    echo "Mirror attempt \${attempt} failed, retrying in 10s..."
    sleep 10
done
echo "Mirroring the tls-scanner image failed after 3 attempts."
exit 1
EOF

echo "${MIRROR_REPO}@${DIGEST}" > "${SHARED_DIR}/tls-scanner-image"
echo "Mirrored scanner image published to ${SHARED_DIR}/tls-scanner-image: ${MIRROR_REPO}@${DIGEST}"
