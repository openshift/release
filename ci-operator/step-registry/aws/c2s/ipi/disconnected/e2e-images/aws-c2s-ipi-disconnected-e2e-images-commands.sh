#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

echo "${MIRROR_REGISTRY_HOST}/e2e/tests" > "${SHARED_DIR}/mirror-tests-image"

echo "Generated e2e image mirror list:"
cat "${SHARED_DIR}/mirror-images-list.yaml"
