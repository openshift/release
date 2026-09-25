#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Generate the mirror list with the SAME openshift-tests binary the suite runs
# with. openshift-e2e-test prepends /usr/libexec/origin to PATH; the "tests"
# image also ships an older openshift-tests earlier on the default PATH, and
# building the list with that stale binary skews the e2e-<N> image tags (older
# agnhost/pause) away from the tags the suite requests at run time, so the
# workload pods fail to pull with "manifest unknown". Match openshift-e2e-test.
export PATH=/usr/libexec/origin:$PATH

# openshift-e2e-test runs on the CI build farm but sources proxy-conf.sh, which
# routes the pod's traffic through the cluster's disconnected proxy. The pod still
# needs to reach hosts the build farm can serve but the disconnected proxy can't
# (503): the build-farm registry (*.ci.openshift.org) and its Cloudflare R2 blob
# store (*.r2.cloudflarestorage.com) for openshift-tests' external test binaries,
# and quay.io for test images the pod pulls directly. Exempt those from the pod's
# NO_PROXY; only the cluster under test stays disconnected.
#
# Do NOT add amazonaws.com: C2S/SC2S emulate the secret-region AWS API by intercepting
# amazonaws.com calls through the proxy, so exempting it would route the pod's AWS
# traffic around the emulation.
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    cat >> "${SHARED_DIR}/proxy-conf.sh" << 'EOF'
export no_proxy="${no_proxy},.ci.openshift.org,r2.cloudflarestorage.com,quay.io"
export NO_PROXY="${NO_PROXY},.ci.openshift.org,r2.cloudflarestorage.com,quay.io"
EOF
    echo "Extended NO_PROXY in proxy-conf.sh for the build-farm registry, R2 blob store, and quay.io"
fi

# Build the list of e2e test images to mirror onto the bastion registry, and
# record that mirror location in mirror-tests-image. openshift-e2e-test reads it
# and passes --from-repository so the disconnected cluster pulls e2e images from
# the bastion instead of the internet.
if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist, skipping e2e image mirror preparation."
    exit 0
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

# "openshift-tests images" emits "<source> <destination>" pairs for this release.
# The next step, mirror-images-qe-test-images, does the actual mirroring.
openshift-tests images --to-repository "${MIRROR_REGISTRY_HOST}/e2e/tests" \
    | grep "${MIRROR_REGISTRY_HOST}/e2e/tests" >> "${SHARED_DIR}/mirror-images-list.yaml"

# "openshift-tests images" omits the registry.k8s.io/pause images (their layers
# are uncompressed, unsupported through the quay.io mirror path) and a few older
# agnhost tags, but the suite still requests them -- rewritten to
# <mirror>/e2e/tests by --from-repository -- so mirror them from source under the
# exact e2e-<N> tags the suite uses. The tag hash is deterministic per source
# image; the index varies by release, so cover the range origin currently uses.
# Kept in sync with the openstack disconnected step (openstack/test/e2e/images).
cat <<EOF >> "${SHARED_DIR}/mirror-images-list.yaml"
registry.k8s.io/pause:3.9 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-27-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.9 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-28-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.10 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-25-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
registry.k8s.io/pause:3.10 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-27-registry-k8s-io-pause-3-10-b3MYAwZ_MelO9baY
registry.k8s.io/pause:3.10.1 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-22-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z
registry.k8s.io/pause:3.10.1 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-25-registry-k8s-io-pause-3-10-1-a6__nK-VRxiifU0Z
registry.k8s.io/pause:3.10.2 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-22-registry-k8s-io-pause-3-10-2-Xnr_kb1i4Z5Tu7vt
registry.k8s.io/e2e-test-images/agnhost:2.47 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-1-registry-k8s-io-e2e-test-images-agnhost-2-47-LZRfusN51OgGfP9f
registry.k8s.io/e2e-test-images/agnhost:2.52 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-1-registry-k8s-io-e2e-test-images-agnhost-2-52-vo_U710PrYLetnfE
registry.k8s.io/e2e-test-images/agnhost:2.59 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-2-registry-k8s-io-e2e-test-images-agnhost-2-59-l6lMl0FrhVtCSA-8
registry.k8s.io/e2e-test-images/agnhost:2.63.0 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-2-registry-k8s-io-e2e-test-images-agnhost-2-63-0-t_yPbigw-dJBrfQ9
EOF

echo "${MIRROR_REGISTRY_HOST}/e2e/tests" > "${SHARED_DIR}/mirror-tests-image"

echo "Generated e2e image mirror list:"
cat "${SHARED_DIR}/mirror-images-list.yaml"
