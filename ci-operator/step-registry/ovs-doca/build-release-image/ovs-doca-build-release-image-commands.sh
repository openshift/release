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
# The rebuilt payload is pushed through the build cluster's integrated
# registry via its in-cluster service DNS, authenticating as this pod's
# service account: step pods cannot push through the external registry route
# (probed in rehearsal 2122363827365351424: "unauthorized: authentication
# required"), but the internal endpoint authorizes by in-namespace RBAC,
# where this pod's service account can write its own job namespace. The
# image is handed to ipi-install as the EXTERNAL pullspec of the very same
# registry image (same registry, same blobs): the install pull-secret
# already authorizes it, since it pulls the default payload from the same
# registry and namespace. The digest-pinned pullspec is written to
# ${SHARED_DIR}/custom-release-image, which the ipi-install step picks up
# (see the SHARED_DIR/custom-release-image support in ipi-install-install-commands).

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"

# 1. Resolve the DOCA-layered RHCOS image. Two modes:
#    - full pullspec (contains '/'): use as-is -- e.g. a quay-hosted image
#      built outside CI (the arm64 build farm cannot produce arm64 images,
#      so the layered image is pre-built and hosted; see the variant docs)
#    - bare name: an imagestream in this job's namespace (an image built by
#      this job's images phase). KUBECONFIG="" makes oc use this pod's
#      service account against the build cluster.
if [[ "${OVS_DOCA_LAYERED_IMAGE}" == */* ]]; then
  LAYERED_REF="${OVS_DOCA_LAYERED_IMAGE}"
  echo "layered image (direct pullspec): ${LAYERED_REF}"
else
  LAYERED_REF=$(KUBECONFIG="" oc get is "${OVS_DOCA_LAYERED_IMAGE}" -o jsonpath='{.status.tags[0].items[0].image}')
  if [[ -z "${LAYERED_REF}" ]]; then
    echo "ERROR: imagestream ${OVS_DOCA_LAYERED_IMAGE} has no built image tag"
    exit 1
  fi
  echo "layered image (job imagestream): ${LAYERED_REF}"
fi

# 2. Destination: same registry and namespace as the default payload, under a
#    dedicated imagestream. The external form is what the installer and the
#    AWS bootstrap node pull (and what the install pull-secret already
#    covers); the internal form -- the in-cluster service DNS of the same
#    registry -- is what this step pushes through, as this pod's service
#    account (the external route rejects pushes from step pods; see the
#    header comment).
REGISTRY_NS="${RELEASE_IMAGE_LATEST%/*}"
JOB_NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
DEST="${REGISTRY_NS}/${OVS_DOCA_RELEASE_IS}:latest"
DEST_INTERNAL="${INTERNAL_REGISTRY}/${JOB_NS}/${OVS_DOCA_RELEASE_IS}:latest"
echo "destination: ${DEST}"
echo "pushing via: ${DEST_INTERNAL}"

# 3. Credentials: the cluster pull-secret covers pulling the source payload
#    and its images; oc registry login appends this pod's service-account
#    token for the external host; and the internal-endpoint entry added
#    below (basic auth with the same service-account token) is what
#    authorizes the push through the in-cluster endpoint.
AUTH_FILE="${SHARED_DIR}/.ovs-doca-pushcreds"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${AUTH_FILE}"
KUBECONFIG="" oc registry login --to="${AUTH_FILE}"
SA_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
jq --arg auth "$(printf 'serviceaccount:%s' "${SA_TOKEN}" | base64 | tr -d '\n')" \
  ".auths[\"${INTERNAL_REGISTRY}\"] = {auth: \$auth}" \
  "${AUTH_FILE}" > "${AUTH_FILE}.tmp" && mv "${AUTH_FILE}.tmp" "${AUTH_FILE}"

# 4. Rebuild the payload with our image as rhel-coreos. Component images are
#    referenced by digest (not copied), so this only assembles and push the
#    release image itself.
echo "oc adm release new --from-release=${RELEASE_IMAGE_LATEST} --to-image=${DEST_INTERNAL} rhel-coreos=${LAYERED_REF}"
oc adm release new --keep-manifest-list \
  -a "${AUTH_FILE}" \
  --from-release="${RELEASE_IMAGE_LATEST}" \
  --to-image="${DEST_INTERNAL}" \
  rhel-coreos="${LAYERED_REF}"

# 5. Pin to digest and hand over to ipi-install via the SHARED_DIR file, as
#    the external pullspec of the just-pushed image.
DIGEST=$(oc adm release info "${DEST_INTERNAL}" -a "${AUTH_FILE}" --output=jsonpath='{.digest}')
if [[ -z "${DIGEST}" ]]; then
  echo "ERROR: could not resolve digest of rebuilt payload ${DEST}"
  exit 1
fi
echo "${DEST%:*}@${DIGEST}" > "${SHARED_DIR}/custom-release-image"
echo "rebuilt payload: ${DEST%:*}@${DIGEST}"
echo "handed over to ipi-install via \${SHARED_DIR}/custom-release-image"
rm -f "${AUTH_FILE}"
