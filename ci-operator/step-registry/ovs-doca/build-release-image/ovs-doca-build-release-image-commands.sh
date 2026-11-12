#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Rebuild the release payload with the DOCA-layered RHCOS image swapped in as
# rhel-coreos, so the cluster can be installed with the layer present from the
# first boot (day-0). This is the manual equivalent of what include_built_images
# does for integration streams, needed here because arm64 candidate payloads
# have no integration stream to carry built images.
#
# The rebuilt payload is pushed to an imagestream in this job's namespace (the
# same registry the default payload already lives in, which the AWS bootstrap
# node pulls with the CI pull-secret), and its pinned pullspec is written to
# ${SHARED_DIR}/custom-release-image, which the ipi-install step picks up (see
# the SHARED_DIR/custom-release-image support in ipi-install-install-commands).

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"

# 1. Resolve the layered image built by this job's images phase: the image is
#    tagged into an imagestream named after the image target. KUBECONFIG=""
#    makes oc use this pod's service account against the build cluster, and
#    the pod's namespace is the job namespace.
LAYERED_REF=$(KUBECONFIG="" oc get is "${OVS_DOCA_LAYERED_IMAGE}" -o jsonpath='{.status.tags[0].items[0].image}')
if [[ -z "${LAYERED_REF}" ]]; then
  echo "ERROR: imagestream ${OVS_DOCA_LAYERED_IMAGE} has no built image tag"
  exit 1
fi
echo "layered image: ${LAYERED_REF}"

# 2. Destination: same registry and namespace as the default payload, under a
#    dedicated imagestream. The external form of this address is exactly what
#    the installer and the AWS bootstrap node already pull for the default
#    payload, so no new registry, credentials or pull-secret entries exist.
REGISTRY_NS="${RELEASE_IMAGE_LATEST%/*}"
DEST="${REGISTRY_NS}/${OVS_DOCA_RELEASE_IS}:latest"
echo "destination: ${DEST}"

# 3. Credentials: the cluster pull-secret covers pulling the source payload and
#    its images; oc registry login appends this pod's service-account token for
#    pushing to the job's registry (same pattern as the quay-omr steps).
AUTH_FILE="${SHARED_DIR}/.ovs-doca-pushcreds"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${AUTH_FILE}"
KUBECONFIG="" oc registry login --to="${AUTH_FILE}"

# 4. Rebuild the payload with our image as rhel-coreos. Component images are
#    referenced by digest (not copied), so this only assembles and push the
#    release image itself.
echo "oc adm release new --from-release=${RELEASE_IMAGE_LATEST} --to-image=${DEST} rhel-coreos=${LAYERED_REF}"
oc adm release new --keep-manifest-list \
  -a "${AUTH_FILE}" \
  --from-release="${RELEASE_IMAGE_LATEST}" \
  --to-image="${DEST}" \
  rhel-coreos="${LAYERED_REF}"

# 5. Pin to digest and hand over to ipi-install via the SHARED_DIR file.
DIGEST=$(oc adm release info "${DEST}" -a "${AUTH_FILE}" --output=jsonpath='{.digest}')
if [[ -z "${DIGEST}" ]]; then
  echo "ERROR: could not resolve digest of rebuilt payload ${DEST}"
  exit 1
fi
echo "${DEST%:*}@${DIGEST}" > "${SHARED_DIR}/custom-release-image"
echo "rebuilt payload: ${DEST%:*}@${DIGEST}"
echo "handed over to ipi-install via \${SHARED_DIR}/custom-release-image"
rm -f "${AUTH_FILE}"
