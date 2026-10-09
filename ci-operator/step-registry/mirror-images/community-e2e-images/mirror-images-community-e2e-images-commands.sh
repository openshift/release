#!/usr/bin/env bash

set -Eeuo pipefail

export PATH=/usr/libexec/origin:$PATH

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist, skipping community e2e image mirroring..."
    exit 0
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
MIRROR_REPO="${MIRROR_REGISTRY_HOST}/${MIRROR_REGISTRY_PATH}"

echo "Discovering community e2e test images required by this release via 'openshift-tests images'..."
openshift-tests images --to-repository "${MIRROR_REPO}" | grep "${MIRROR_REPO}" >> "${SHARED_DIR}/mirror-images-list.yaml"

# `openshift-tests images` does not include the current registry.k8s.io/pause
# tags in its output (their layers aren't compressed, which quay.io's mirror
# path used to compute the tool's output doesn't support). Since pause is the
# pod sandbox/infra container used by virtually every pod, missing it breaks
# almost every test in a disconnected cluster. Mirror the known versions
# explicitly as a workaround, matching the same fallback used by
# openstack-test-e2e-images.
#
# Also push each version under its own plain tag (in addition to the e2e-*
# destination tags openshift-tests' --from-repository rewriting expects):
# the generated ImageTagMirrorSet below maps source: registry.k8s.io/pause to
# this repo tag-for-tag, so *any* direct pull of registry.k8s.io/pause:<tag>
# (not just ones openshift-tests rewrote) gets redirected to
# ${MIRROR_REPO}:<tag> — which must therefore also exist.
cat <<EOF >> "${SHARED_DIR}/mirror-images-list.yaml"
registry.k8s.io/pause:3.9 ${MIRROR_REPO}:e2e-27-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.9 ${MIRROR_REPO}:e2e-28-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.9 ${MIRROR_REPO}:3.9
registry.k8s.io/pause:3.10 ${MIRROR_REPO}:e2e-25-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
registry.k8s.io/pause:3.10 ${MIRROR_REPO}:e2e-27-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
registry.k8s.io/pause:3.10 ${MIRROR_REPO}:3.10
registry.k8s.io/pause:3.10.1 ${MIRROR_REPO}:e2e-22-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z
registry.k8s.io/pause:3.10.1 ${MIRROR_REPO}:e2e-25-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z
registry.k8s.io/pause:3.10.1 ${MIRROR_REPO}:3.10.1
registry.k8s.io/pause:3.10.2 ${MIRROR_REPO}:e2e-22-registry-k8s-io-pause-3-10-2-Xnr_kb1i4Z5Tu7vt
registry.k8s.io/pause:3.10.2 ${MIRROR_REPO}:3.10.2
EOF

# The ovn-kubernetes-tests-ext test extension (owns the
# [Feature:NetworkSegmentation] user-defined-network tests) reports null
# images to 'openshift-tests images' (confirmed via that command's own log:
# `Extension "ovn-kubernetes-tests-ext" reported null images, treating as
# empty`), so any image it needs that isn't already covered by k8s-tests-ext
# is silently missing from discovery. This broke every UDN test in a
# disconnected run (~29 failures) on ImagePullBackOff for agnhost:2.63.0.
# The image is still published under the same deterministic tag in
# quay.io/openshift/community-e2e-images (confirmed via the failing pod's
# requested destination tag, which openshift-tests computes independently of
# what we mirror), so mirror it explicitly as a fallback, same pattern as
# the pause workaround above. If future releases bump the ovn-kubernetes
# agnhost version again, this will need updating the same way.
cat <<EOF >> "${SHARED_DIR}/mirror-images-list.yaml"
quay.io/openshift/community-e2e-images:e2e-2-registry-k8s-io-e2e-test-images-agnhost-2-63-0-t_yPbigw-dJBrfQ9 ${MIRROR_REPO}:e2e-2-registry-k8s-io-e2e-test-images-agnhost-2-63-0-t_yPbigw-dJBrfQ9
EOF

if [[ -n "${EXTRA_MIRROR_IMAGES}" ]]; then
    echo "Appending EXTRA_MIRROR_IMAGES entries:"
    echo "${EXTRA_MIRROR_IMAGES}"
    echo "${EXTRA_MIRROR_IMAGES}" >> "${SHARED_DIR}/mirror-images-list.yaml"
fi

echo "${MIRROR_REPO}" > "${SHARED_DIR}/mirror-tests-image"
echo "Generated list of images to mirror on ${MIRROR_REPO}:"
cat "${SHARED_DIR}/mirror-images-list.yaml"

cat <<EOF > /tmp/idms.yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: mirror-e2e-tests
spec:
  imageDigestMirrors:
EOF
cat <<EOF > /tmp/itms.yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: mirror-e2e-tests
spec:
  imageTagMirrors:
EOF
SOURCE_IMAGES=$(awk '{print $1}' "${SHARED_DIR}/mirror-images-list.yaml" | sed -E 's/@[^[:space:]]+$//; s#:[^:/]+$##' | sort -u)
for SOURCE_IMAGE in $SOURCE_IMAGES; do
    cat <<EOF >> /tmp/idms.yaml
  - mirrors:
    - ${MIRROR_REPO}
    source: ${SOURCE_IMAGE}
EOF
    cat <<EOF >> /tmp/itms.yaml
  - mirrors:
    - ${MIRROR_REPO}
    source: ${SOURCE_IMAGE}
EOF
done
echo "Generated ImageDigestMirrorSet and ImageTagMirrorSet:"
cat /tmp/idms.yaml
cat /tmp/itms.yaml

echo "Applying ImageDigestMirrorSet and ImageTagMirrorSet..."
oc apply -f /tmp/idms.yaml
oc apply -f /tmp/itms.yaml

echo "Done"
