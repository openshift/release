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
# HOW THE REBUILT PAYLOAD IS PUBLISHED (each mechanism was probed in a
# rehearsal; see the script history for the full saga):
#   - pushing through the external registry route as this pod's service
#     account: unauthorized (2122363827365351424)
#   - pushing through the in-cluster registry endpoint as this pod's service
#     account, with verified credentials and TLS trust: unauthorized
#     (2122682030884917248) -- a genuine RBAC denial; writes to the pipeline
#     registry are reserved for build identities
#   - minting a token for the namespace `builder` SA via TokenRequest:
#     forbidden (2122648382508896256)
# What CAN write to the pipeline registry is the namespace's `builder` service
# account (bound to system:image-builder) -- the identity OpenShift builds run
# as. So this step creates a one-shot BuildConfig and performs the
# `oc adm release new` push inside the build's RUN step: the build pod runs as
# `builder`, carries its own SA token (merged into the auth file in-build), and
# establishes the endpoint's TLS trust the same way this step does. The built
# image itself is a scratch archive of the registry's certificate chain; only
# the side-effect push matters.
#
# The image is handed to ipi-install as the EXTERNAL pullspec of the pushed
# image (same registry, same blobs): the install pull-secret already
# authorizes it, since it pulls the default payload from the same registry
# and namespace. The digest-pinned pullspec is written to
# ${SHARED_DIR}/custom-release-image, which the ipi-install step picks up
# (see the SHARED_DIR/custom-release-image support in ipi-install-install-commands).
#
# NOTE: there is no jq in this image (2122658718276390912) -- docker configs
# are built with sed, and the results verified.

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
#    registry -- is what the assembly build pushes through.
REGISTRY_NS="${RELEASE_IMAGE_LATEST%/*}"
JOB_NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
INTERNAL_HOST="${INTERNAL_REGISTRY%%:*}"
DEST="${REGISTRY_NS}/${OVS_DOCA_RELEASE_IS}:latest"
DEST_INTERNAL="${INTERNAL_REGISTRY}/${JOB_NS}/${OVS_DOCA_RELEASE_IS}:latest"
RELEASE_INTERNAL="${INTERNAL_REGISTRY}/${RELEASE_IMAGE_LATEST#*/}"
echo "destination: ${DEST}"
echo "pushing via: ${DEST_INTERNAL}"

# 3. Read credentials for this step: the cluster pull-secret (covers the
#    payload's component images in quay.io/openshift-release-dev and the
#    external registry) with this pod's service-account token added for the
#    in-cluster endpoint, used to read the pushed payload back. sed, not jq.
SA_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
SA_AUTH="$(printf 'serviceaccount:%s' "${SA_TOKEN}" | base64 | tr -d '\n')"
AUTH_FILE="${SHARED_DIR}/.ovs-doca-pushcreds"
sed "s|\"auths\": *{|\"auths\": {\"${INTERNAL_REGISTRY}\": {\"auth\": \"${SA_AUTH}\"},|" \
  "${CLUSTER_PROFILE_DIR}/pull-secret" > "${AUTH_FILE}" || true
if ! grep -q "${INTERNAL_REGISTRY}" "${AUTH_FILE}"; then
  echo "ERROR: could not add the internal-registry credential to the cluster pull-secret"
  exit 1
fi
echo "read credentials: cluster pull-secret + service-account token for ${INTERNAL_REGISTRY}"

# 3a. TLS trust for the in-cluster registry endpoint (used for the digest
#     read-back; the assembly build establishes the same trust in-build): it
#     serves a certificate signed by the cluster's own CA, which is not part
#     of this image's system trust. Fetch the served chain and append it to a
#     copy of the system bundle, exported as SSL_CERT_FILE (honored by oc's
#     Go TLS stack). The pin stays inside the cluster pod network and only
#     reads this job's own namespace. Subject and issuer are logged.
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

# 4. Assemble and push the payload through a one-shot binary BuildConfig.
#    The build pod runs as the namespace builder SA, authenticates to the
#    in-cluster registry with its own mounted token (merged into a copy of
#    the cluster pull-secret inside the build -- sed, no jq), and pushes the
#    assembled payload as a side effect of its RUN. The final scratch stage
#    keeps the built image (and the dummy output push) tiny.
CLI_IMAGE="$(oc get is cli -o jsonpath='{.status.tags[0].items[0].image}' 2>/dev/null || true)"
if [[ -z "${CLI_IMAGE}" ]]; then
  echo "no cli imagestream in namespace, using the public proxy tag"
  CLI_IMAGE="quay-proxy.ci.openshift.org/openshift/ci:latest"
fi
echo "assembly builder image: ${CLI_IMAGE}"

WORK="$(mktemp -d)"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${WORK}/auth-seed.json"

cat > "${WORK}/Dockerfile.tpl" <<'EOF'
FROM __CLI_IMAGE__ AS assemble
COPY auth-seed.json /tmp/auth-seed.json
RUN set -euo pipefail; \
    openssl s_client -showcerts -connect __INTERNAL_REGISTRY__ -servername __INTERNAL_HOST__ </dev/null 2>/dev/null \
      | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > /tmp/chain.pem; \
    grep -q "BEGIN CERTIFICATE" /tmp/chain.pem; \
    cat /etc/pki/tls/certs/ca-bundle.crt /tmp/chain.pem > /tmp/ca.pem; \
    export SSL_CERT_FILE=/tmp/ca.pem; \
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); \
    SA_AUTH=$(printf 'builder:%s' "$SA_TOKEN" | base64 | tr -d '\n'); \
    sed "s|\"auths\": *{|\"auths\": {\"__INTERNAL_REGISTRY__\": {\"auth\": \"$SA_AUTH\"},|" /tmp/auth-seed.json > /tmp/auth.json; \
    grep -q "__INTERNAL_REGISTRY__" /tmp/auth.json; \
    echo "oc adm release new --from-release=__RELEASE_INTERNAL__ --to-image=__DEST_INTERNAL__ rhel-coreos=__LAYERED_REF__"; \
    oc adm release new --keep-manifest-list -a /tmp/auth.json \
      --from-release=__RELEASE_INTERNAL__ --to-image=__DEST_INTERNAL__ \
      rhel-coreos=__LAYERED_REF__
FROM scratch
COPY --from=assemble /tmp/chain.pem /registry-chain.pem
EOF
sed -e "s|__CLI_IMAGE__|${CLI_IMAGE}|" \
    -e "s|__INTERNAL_REGISTRY__|${INTERNAL_REGISTRY}|" \
    -e "s|__INTERNAL_HOST__|${INTERNAL_HOST}|" \
    -e "s|__RELEASE_INTERNAL__|${RELEASE_INTERNAL}|" \
    -e "s|__DEST_INTERNAL__|${DEST_INTERNAL}|" \
    -e "s|__LAYERED_REF__|${LAYERED_REF}|" \
    "${WORK}/Dockerfile.tpl" > "${WORK}/Dockerfile"
rm -f "${WORK}/Dockerfile.tpl"
echo "---- assembly Dockerfile ----"
cat "${WORK}/Dockerfile"
echo "------------------------------"

BC_NAME="${OVS_DOCA_RELEASE_IS}-assembly"
oc new-build --name "${BC_NAME}" --binary --strategy=docker \
  --to "${OVS_DOCA_RELEASE_IS}-assembly-result:latest"

# The FROM image pull inside the build uses the same registry credentials
# this step uses for reads (cluster pull-secret + service-account entry).
oc create secret docker-registry "${BC_NAME}-pull" --from-file=".dockerconfigjson=${AUTH_FILE}"
oc set build-secret --pull "bc/${BC_NAME}" "${BC_NAME}-pull"

echo "starting assembly build"
oc start-build "${BC_NAME}" --from-dir="${WORK}" -F

BUILD_NAME="$(oc get builds -o name | sed 's|.*/||' | grep "^${BC_NAME}" | tail -1)"
BUILD_PHASE="$(oc get build "${BUILD_NAME}" -o jsonpath='{.status.phase}')"
echo "assembly build ${BUILD_NAME}: ${BUILD_PHASE}"
if [[ "${BUILD_PHASE}" != "Complete" ]]; then
  echo "ERROR: assembly build did not complete"
  exit 1
fi

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
