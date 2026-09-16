#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# openshift-e2e-test runs on the CI build farm but sources proxy-conf.sh, which
# sends its traffic through the cluster's disconnected proxy. The pod still needs
# to pull openshift-tests' external test binaries from the build-farm registry,
# and routing that through the proxy fails with a 503. Only the cluster has to
# stay disconnected, so exclude the build-farm domain from the pod's NO_PROXY.
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    cat >> "${SHARED_DIR}/proxy-conf.sh" << 'EOF'
export no_proxy="${no_proxy},.ci.openshift.org"
export NO_PROXY="${NO_PROXY},.ci.openshift.org"
EOF
    echo "Extended NO_PROXY in proxy-conf.sh with .ci.openshift.org"
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
