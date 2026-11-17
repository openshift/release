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
# HOW THE REBUILT PAYLOAD IS PUBLISHED (hard-won knowledge, see the rehearsal
# references below): writes into the build cluster's pipeline registry are
# reserved for build identities.
#   - pushing through the external registry route as this pod's service
#     account: unauthorized (rehearsal 2122363827365351424)
#   - pushing through the in-cluster registry endpoint as this pod's service
#     account (after fixing the endpoint's TLS trust): unauthorized
#     (rehearsal 2122644178016931840)
#   - minting a token for the namespace `builder` SA via TokenRequest:
#     forbidden -- step service accounts cannot create serviceaccounts/token
#     (rehearsal 2122648382508896256)
# What CAN write to the pipeline registry is the namespace's `builder` service
# account (bound to system:image-builder) -- the identity OpenShift builds run
# as. So this step creates a one-shot BuildConfig whose docker build performs
# the `oc adm release new` push as a side effect of its RUN step: the build
# pod runs as `builder`, carries its own SA token (used as the push
# credential), and the endpoint's TLS trust is established inside the build
# the same way as in this step. The built image itself is a scratch archive
# of the registry's certificate chain; only the side-effect push matters.
#
# The image is handed to ipi-install as the EXTERNAL pullspec of the pushed
# image (same registry, same blobs): the install pull-secret already
# authorizes it, since it pulls the default payload from the same registry
# and namespace. The digest-pinned pullspec is written to
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
#    registry -- is what the assembly build pushes through, as the builder
#    service account.
REGISTRY_NS="${RELEASE_IMAGE_LATEST%/*}"
JOB_NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
INTERNAL_HOST="${INTERNAL_REGISTRY%%:*}"
DEST="${REGISTRY_NS}/${OVS_DOCA_RELEASE_IS}:latest"
DEST_INTERNAL="${INTERNAL_REGISTRY}/${JOB_NS}/${OVS_DOCA_RELEASE_IS}:latest"
echo "destination: ${DEST}"
echo "pushing via: ${DEST_INTERNAL}"

# 3. Credentials for everything this step pulls directly (source payload and
#    component images through the external route; quay-hosted layered image)
#    and for reading the pushed payload back through the internal endpoint.
#    The push credential lives only inside the assembly build (its own
#    service-account token); it is never present in this step.
AUTH_FILE="${SHARED_DIR}/.ovs-doca-pushcreds"
cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${AUTH_FILE}"
KUBECONFIG="" oc registry login --to="${AUTH_FILE}"
SA_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
jq --arg auth "$(printf 'serviceaccount:%s' "${SA_TOKEN}" | base64 | tr -d '\n')" \
  ".auths[\"${INTERNAL_REGISTRY}\"] = {auth: \$auth}" \
  "${AUTH_FILE}" > "${AUTH_FILE}.tmp" && mv "${AUTH_FILE}.tmp" "${AUTH_FILE}"

# 3a. TLS trust for the in-cluster registry endpoint: it serves a certificate
#     signed by the cluster's own CA, which is not part of the cli image's
#     system trust (reading through it otherwise fails with "x509:
#     certificate signed by unknown authority"). Fetch the registry's served
#     certificate chain and append it to a copy of the system bundle,
#     exported as SSL_CERT_FILE, which oc's Go TLS stack honors. Trusting
#     the served certificate pins the cluster's current registry
#     certificate: acceptable here because the connection stays inside the
#     cluster's pod network and only reads this job's own namespace.
#     Subject and issuer are logged for the record.
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

# 4. Assemble and push the payload through a one-shot BuildConfig. The build
#    pod runs as the namespace's builder SA (the only pipeline-registry write
#    identity), authenticates to the in-cluster registry with its own mounted
#    token, and establishes the same TLS trust inside the build. The final
#    scratch stage keeps the built image (and the dummy output push) tiny:
#    only the side-effect push of the assembled payload matters.
CLI_IMAGE="$(oc get is cli -o jsonpath='{.status.tags[0].items[0].image}' 2>/dev/null || true)"
if [[ -z "${CLI_IMAGE}" ]]; then
  echo "WARNING: no cli imagestream in namespace, falling back to the public proxy tag"
  CLI_IMAGE="quay-proxy.ci.openshift.org/openshift/ci:latest"
fi
echo "assembly builder image: ${CLI_IMAGE}"

WORK="$(mktemp -d)"
cp "${AUTH_FILE}" "${WORK}/auth.json"

cat > "${WORK}/Dockerfile.tpl" <<'EOF'
FROM __CLI_IMAGE__ AS assemble
COPY auth.json /tmp/auth.json
RUN set -euo pipefail; \
    openssl s_client -showcerts -connect __INTERNAL_REGISTRY__ -servername __INTERNAL_HOST__ </dev/null 2>/dev/null \
      | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > /tmp/chain.pem; \
    grep -q "BEGIN CERTIFICATE" /tmp/chain.pem; \
    cat /etc/pki/tls/certs/ca-bundle.crt /tmp/chain.pem > /tmp/ca.pem; \
    export SSL_CERT_FILE=/tmp/ca.pem; \
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); \
    jq --arg auth "$(printf 'builder:%s' "$SA_TOKEN" | base64 | tr -d '\n')" \
      '.auths["__INTERNAL_REGISTRY__"] = {auth: $auth}' /tmp/auth.json > /tmp/auth2.json; \
    echo "oc adm release new --from-release=__RELEASE_IMAGE_LATEST__ --to-image=__DEST_INTERNAL__ rhel-coreos=__LAYERED_REF__"; \
    oc adm release new --keep-manifest-list -a /tmp/auth2.json \
      --from-release=__RELEASE_IMAGE_LATEST__ --to-image=__DEST_INTERNAL__ \
      rhel-coreos=__LAYERED_REF__
FROM scratch
COPY --from=assemble /tmp/chain.pem /registry-chain.pem
EOF
sed -e "s|__CLI_IMAGE__|${CLI_IMAGE}|" \
    -e "s|__INTERNAL_REGISTRY__|${INTERNAL_REGISTRY}|" \
    -e "s|__INTERNAL_HOST__|${INTERNAL_HOST}|" \
    -e "s|__RELEASE_IMAGE_LATEST__|${RELEASE_IMAGE_LATEST}|" \
    -e "s|__DEST_INTERNAL__|${DEST_INTERNAL}|" \
    -e "s|__LAYERED_REF__|${LAYERED_REF}|" \
    "${WORK}/Dockerfile.tpl" > "${WORK}/Dockerfile"
rm -f "${WORK}/Dockerfile.tpl"
echo "---- assembly Dockerfile ----"
cat "${WORK}/Dockerfile"
echo "------------------------------"

BC_NAME="${OVS_DOCA_RELEASE_IS}-assembly"
jq -n --arg df "$(cat "${WORK}/Dockerfile")" --arg name "${BC_NAME}" \
       --arg to "${OVS_DOCA_RELEASE_IS}-assembly-result:latest" \
  '{apiVersion: "build.openshift.io/v1", kind: "BuildConfig",
    metadata: {name: $name},
    spec: {runPolicy: "Serial",
           source: {type: "Binary", dockerfile: $df},
           strategy: {type: "Docker", dockerStrategy: {}},
           output: {to: {kind: "ImageStreamTag", name: $to}}}}' | oc apply -f -

# The FROM image pull inside the build uses the same registry credentials
# this step uses (cluster pull-secret + service-account login).
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
