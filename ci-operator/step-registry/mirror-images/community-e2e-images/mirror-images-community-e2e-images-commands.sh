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
SOURCE_IMAGES=$(awk '{print $1}' "${SHARED_DIR}/mirror-images-list.yaml" | sort | cut -d':' -f1 | uniq)
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
