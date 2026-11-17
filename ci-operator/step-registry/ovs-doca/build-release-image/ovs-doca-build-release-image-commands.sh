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
# The rebuilt payload is pushed through the build cluster's in-cluster
# registry (its service DNS) authenticating as the job namespace's `builder`
# service account: step pods cannot push through the external registry route
# (probed in rehearsal 2122363827365351424: "unauthorized: authentication
# required") nor as their own service account through the in-cluster endpoint
# (probed in rehearsal 2122644178016931840, same denial after the endpoint's
# TLS trust was fixed) -- writes to the pipeline registry are reserved for
# build identities, and `builder` carries exactly that role
# (system:image-builder) in every namespace. The image is handed to
# ipi-install as the EXTERNAL pullspec of the very same registry image (same
# registry, same blobs): the install pull-secret already authorizes it,
# since it pulls the default payload from the same registry and namespace.
# The digest-pinned pullspec is written to
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
#    token for the external host. The push identity is the namespace's
#    `builder` service account: the step pod's own SA cannot push to the
#    registry (probed: "unauthorized" through both the external route and
#    the in-cluster endpoint -- writes into the pipeline registry are
#    reserved for build identities), while `builder` is bound to
#    system:image-builder, the role OpenShift builds use to push into the
#    namespace's imagestreams. A short-lived token is minted for it via
#    TokenRequest and used as the basic-auth password for the internal
#    registry entry (the registry's auth middleware validates the token via
#    TokenReview; the username is not significant).
AUTH_FILE="${SHARED_DIR}/.ovs-doca-pushcreds"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${AUTH_FILE}"
KUBECONFIG="" oc registry login --to="${AUTH_FILE}"
BUILDER_TOKEN="$(KUBECONFIG="" oc create token builder -n "${JOB_NS}" --duration=2h)"
jq --arg auth "$(printf 'builder:%s' "${BUILDER_TOKEN}" | base64 | tr -d '\n')" \
  ".auths[\"${INTERNAL_REGISTRY}\"] = {auth: \$auth}" \
  "${AUTH_FILE}" > "${AUTH_FILE}.tmp" && mv "${AUTH_FILE}.tmp" "${AUTH_FILE}"

# 3a. TLS trust for the in-cluster registry endpoint: it serves a certificate
#     signed by the cluster's own CA, which is not part of the cli image's
#     system trust (pushing through it otherwise fails with "x509:
#     certificate signed by unknown authority"). Fetch the registry's served
#     certificate chain and append it to a copy of the system bundle, exported
#     as SSL_CERT_FILE, which oc's Go TLS stack honors. Trusting the served
#     certificate pins the cluster's current registry certificate: acceptable
#     here because the connection stays inside the cluster's pod network,
#     authenticates as this pod's service account, and writes only to this
#     job's own namespace. Subject and issuer are logged for the record.
INTERNAL_HOST="${INTERNAL_REGISTRY%%:*}"
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
rm -f "${AUTH_FILE}" "${REGISTRY_CHAIN}" "${SHARED_DIR}/.ovs-doca-ca.pem"
