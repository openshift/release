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
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist, skipping..."
    exit 0
fi
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`

openshift-tests images --to-repository "${MIRROR_REGISTRY_HOST}/e2e/tests" >> "${SHARED_DIR}/mirror-images-list.yaml"
# "registry.k8s.io/pause:XX" is excluded from the output of the "openshift-tests images" command as some of the layers
# aren't compressed and this isn't supported by quay.io. So we need to mirror it from source bypassing quay.io.
cat <<EOF >> "${SHARED_DIR}/mirror-images-list.yaml"
registry.k8s.io/pause:3.9 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-27-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
registry.k8s.io/pause:3.9 ${MIRROR_REGISTRY_HOST}/e2e/tests:e2e-28-registry-k8s-io-pause-3-9-p9APyPDU5GsW02Rk
EOF

echo "${MIRROR_REGISTRY_HOST}/e2e/tests" > "${SHARED_DIR}/mirror-tests-image"
echo "Generated a list of images to mirror on ${MIRROR_REGISTRY_HOST}/e2e/tests :"
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
SOURCE_IMAGES=$(awk '{print $1}' "${SHARED_DIR}/mirror-images-list.yaml" | sort | cut -d':' -f1 | uniq)
for SOURCE_IMAGE in $SOURCE_IMAGES; do
    cat <<EOF >> /tmp/idms.yaml
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/e2e/tests
    source: ${SOURCE_IMAGE}
EOF
    cat <<EOF >> /tmp/itms.yaml
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/e2e/tests
    source: ${SOURCE_IMAGE}
EOF
done
echo "Generated ImageDigestMirrorSet and ImageTagMirrorSet files:"
cat /tmp/idms.yaml
cat /tmp/itms.yaml

echo "Apply ImageDigestMirrorSet and ImageTagMirrorSet:"
oc apply -f /tmp/idms.yaml
oc apply -f /tmp/itms.yaml

echo "Done"
