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
# HOW THE REBUILT PAYLOAD IS PUBLISHED: pushed through the build cluster's
# in-cluster registry endpoint (its service DNS) as this pod's service account,
# using basic auth (the registry's auth middleware validates the token via
# TokenReview; the username is not significant). The endpoint serves a
# certificate signed by the cluster's own CA, so the served chain is fetched
# and exported via SSL_CERT_FILE for oc's Go TLS stack. The image is handed to
# ipi-install as the EXTERNAL pullspec of the very same registry image (same
# registry, same blobs): the install pull-secret already authorizes it, since
# it pulls the default payload from the same registry and namespace. The
# digest-pinned pullspec is written to ${SHARED_DIR}/custom-release-image,
# which the ipi-install step picks up (see the SHARED_DIR/custom-release-image
# support in ipi-install-install-commands).
#
# Pushes through the EXTERNAL registry route are denied for step pods
# (rehearsal 2122363827365351424: "unauthorized: authentication required").
#
# NOTE: no jq in this image (rehearsal 2122658718276390912: "jq: command not
# found" -- and because the failed merge sat inside a && list, errexit did not
# stop the script, so the previous internal-push attempt ran with NO registry
# credentials attached at all; its "unauthorized" was unauthenticated, not an
# RBAC denial). All docker configs below are built with printf instead.

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
#    registry -- is what this step pushes through.
REGISTRY_NS="${RELEASE_IMAGE_LATEST%/*}"
EXTERNAL_REGISTRY="${RELEASE_IMAGE_LATEST%%/*}"
JOB_NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
INTERNAL_HOST="${INTERNAL_REGISTRY%%:*}"
DEST="${REGISTRY_NS}/${OVS_DOCA_RELEASE_IS}:latest"
DEST_INTERNAL="${INTERNAL_REGISTRY}/${JOB_NS}/${OVS_DOCA_RELEASE_IS}:latest"
RELEASE_INTERNAL="${INTERNAL_REGISTRY}/${RELEASE_IMAGE_LATEST#*/}"
echo "destination: ${DEST}"
echo "pushing via: ${DEST_INTERNAL}"

# 3. Push credentials: this pod's service-account token as basic auth for
#    the in-cluster registry endpoint (and the same token works for pulling
#    the source payload and component images through the internal form of
#    the same registry -- no external-route round trip, no cluster pull-secret
#    needed). Built with printf: there is no jq in this image.
SA_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
SA_AUTH="$(printf 'serviceaccount:%s' "${SA_TOKEN}" | base64 | tr -d '\n')"
AUTH_FILE="${SHARED_DIR}/.ovs-doca-pushcreds"
printf '{"auths":{"%s":{"auth":"%s"}}}' "${INTERNAL_REGISTRY}" "${SA_AUTH}" > "${AUTH_FILE}"
grep -q "auths" "${AUTH_FILE}" || { echo "ERROR: could not build push credentials"; exit 1; }
echo "push credentials: service-account token for ${INTERNAL_REGISTRY}"

# 3a. TLS trust for the in-cluster registry endpoint: it serves a certificate
#     signed by the cluster's own CA, which is not part of this image's
#     system trust (pushing through it otherwise fails with "x509:
#     certificate signed by unknown authority"). Fetch the registry's served
#     certificate chain and append it to a copy of the system bundle,
#     exported as SSL_CERT_FILE, which oc's Go TLS stack honors. Trusting
#     the served certificate pins the cluster's current registry
#     certificate: acceptable here because the connection stays inside the
#     cluster's pod network, authenticates as this pod's service account,
#     and writes only to this job's own namespace. Subject and issuer are
#     logged for the record.
REGISTRY_CHAIN="${SHARED_DIR}/.ovs-doca-registry-chain.pem"
openssl s_client -showcerts -connect "${INTERNAL_REGISTRY}" -servername "${INTERNAL_HOST}" </dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${REGISTRY_CHAIN}" || true
if ! grep -q "BEGIN CERTIFICATE" "${REGISTRY_CHAIN}"; then
  echo "ERROR: could not fetch the certificate chain of ${INTERNAL_REGISTRY}"
  exit 1
fi
openssl x509 -in "${REGISTRY_CHAIN}" -noout -subject -issuer 2>/dev/null || true
SYS_BUNDLE="$(ls /etc/pki/tls/certs/ca-bundle.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem 2>/dev/null | head -1)"
cat "${SYS_BUNDLE:-/dev/null}" "${REGISTRY_CHAIN}" > "${SHARED_DIR}/.ovs-doca-ca.pem"
export SSL_CERT_FILE="${SHARED_DIR}/.ovs-doca-ca.pem"
echo "SSL_CERT_FILE: system bundle (${SYS_BUNDLE:-none}) + registry chain"

# 4. Rebuild the payload with our image as rhel-coreos. Component images are
#    referenced by digest (not copied), so this only assembles and pushes the
#    release image itself. The source payload is pulled through its in-cluster
#    form (same registry, same blobs, same credentials).
echo "oc adm release new --from-release=${RELEASE_INTERNAL} --to-image=${DEST_INTERNAL} rhel-coreos=${LAYERED_REF}"
oc adm release new --keep-manifest-list \
  -a "${AUTH_FILE}" \
  --from-release="${RELEASE_INTERNAL}" \
  --to-image="${DEST_INTERNAL}" \
  rhel-coreos="${LAYERED_REF}"

# 5. Pin to digest and hand over to ipi-install via the SHARED_DIR file, as
#    the external pullspec of the pushed image.
DIGEST=$(oc adm release info "${DEST_INTERNAL}" -a "${AUTH_FILE}" --output=jsonpath='{.digest}')
if [[ -z "${DIGEST}" ]]; then
  echo "ERROR: could not resolve digest of rebuilt payload ${DEST_INTERNAL}"
  exit 1
fi
echo "${DEST%:*}@${DIGEST}" > "${SHARED_DIR}/custom-release-image"
echo "rebuilt payload: ${DEST%:*}@${DIGEST}"
echo "handed over to ipi-install via \${SHARED_DIR}/custom-release-image"
rm -f "${AUTH_FILE}" "${REGISTRY_CHAIN}" "${SHARED_DIR}/.ovs-doca-ca.pem"
