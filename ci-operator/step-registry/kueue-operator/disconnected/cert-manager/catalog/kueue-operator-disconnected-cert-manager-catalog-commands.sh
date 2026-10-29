#!/usr/bin/env bash

set -euo pipefail

# Kueue needs only the operator and its declared images, not cert-manager's test
# images. Keep this preparation separate and reuse the shared operator installer.
function diagnostics() {
    oc get mcp || true
    oc get catalogsource,pods -n openshift-marketplace || true
    oc get events -n openshift-marketplace --sort-by=.lastTimestamp || true
}
trap diagnostics ERR

source "${SHARED_DIR}/proxy-conf.sh"
: "${CATSRC_IMG:?A cert-manager catalog image is required}"
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
: "${MIRROR_REGISTRY_HOST:?A disconnected mirror registry is required}"

TMP_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR="${TMP_DIR}/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "${TMP_DIR}"
umask 077

# Use profile credentials rather than retrieving the cluster pull secret.
REDHAT_AUTH=$(jq -r '[.user, .password] | join(":") | @base64' /var/run/vault/mirror-registry/registry_redhat.json)
STAGE_AUTH=$(jq -r '[.user, .password] | join(":") | @base64' /var/run/vault/mirror-registry/registry_stage.json)
MIRROR_AUTH=$(head -n 1 /var/run/vault/mirror-registry/registry_creds | base64 -w 0)
jq --arg redhat "${REDHAT_AUTH}" --arg stage "${STAGE_AUTH}" \
    --arg host "${MIRROR_REGISTRY_HOST}" --arg mirror "${MIRROR_AUTH}" \
    '.auths += {"registry.redhat.io": {auth: $redhat}, "registry.stage.redhat.io": {auth: $stage}, ($host): {auth: $mirror}}' \
    "${CLUSTER_PROFILE_DIR}/pull-secret" > "${XDG_RUNTIME_DIR}/containers/auth.json"

# oc-mirror requires readable catalog content for the non-root registry server.
umask 022

ARCH=$(uname -m)
case "${ARCH}" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
esac
curl -kfL -o oc-mirror.tar.gz "https://openshift-mirror-list.ci-systems.workers.dev/pub/cgw/oc-mirror/latest/oc-mirror-rhel9-linux-${ARCH}.tar.gz"
tar -xzf oc-mirror.tar.gz
chmod +x oc-mirror

# Mirror channel heads and bundle-declared images, without pinning a cert-manager
# version or maintaining a separate operand image list.
cat > imageset.yaml <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${CATSRC_IMG}
    packages:
    - name: openshift-cert-manager-operator
EOF
env -u REGISTRY_AUTH_FILE ./oc-mirror --v2 --config=imageset.yaml \
    --workspace="file://${TMP_DIR}" "docker://${MIRROR_REGISTRY_HOST}" \
    --log-level=info --retry-times=5 --src-tls-verify=false --dest-tls-verify=false

OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
curl -kfL -o yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}"
chmod +x yq
export CATSRC_NAME
./yq eval '.metadata.name = strenv(CATSRC_NAME)' -i "${OUTPUT_DIR}"/cs-*.yaml
oc apply -f "${OUTPUT_DIR}"

# Do not require observing the transient Updating=True condition.
oc wait mcp --all --for=condition=Updated --timeout=20m
oc wait "catalogsource/${CATSRC_NAME}" -n openshift-marketplace \
    --for=jsonpath='{.status.connectionState.lastObservedState}'=READY --timeout=5m

# The shared installer can skip installation when a package is missing. Fail
# here instead, and verify its subscription channel is available as well.
for attempt in $(seq 1 60); do
    if oc get packagemanifest -n openshift-marketplace \
        -l "catalog=${CATSRC_NAME}" --field-selector=metadata.name=openshift-cert-manager-operator -o json | \
        jq -e --arg channel "${CHANNEL}" --arg catalog "${CATSRC_NAME}" \
            'any(.items[]?; .status.catalogSource == $catalog and any(.status.channels[]?; .name == $channel))' >/dev/null; then
        echo "${CATSRC_NAME}" > "${SHARED_DIR}/catsrc_name"
        echo "Cert-manager catalog and channel ${CHANNEL} are ready for the shared installer"
        exit 0
    fi
    echo "Waiting for cert-manager channel ${CHANNEL} in ${CATSRC_NAME} (${attempt}/60)"
    sleep 5
done
echo "Cert-manager package/channel ${CHANNEL} did not become available in ${CATSRC_NAME}"
diagnostics
exit 1
