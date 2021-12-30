#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"

if [ ! -f "${SHARED_DIR}/allsubnetids" ]; then
    echo "File ${SHARED_DIR}/allsubnetids does not exist."
    exit 1
fi

MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirrorregistryhost"`
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

target_release_image="${MIRROR_REGISTRY_HOST}/${RELEASE_IMAGE_LATEST#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"

mirror_output="${SHARED_DIR}/mirror_output"
oc registry login

# add registry credential to default pull secret
# default pull secret ${CLUSTER_PROFILE_DIR}/pull-secret

registry_cred=`head -n 1 "${CLUSTER_PROFILE_DIR}/registry_credential_base64"`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > /tmp/new-pull-secret


# check if registry works well 
# registry_cred_text=$(echo $registry_cred | base64 -d)
# echo "running: curl -k https://${MIRROR_REGISTRY_HOST}/v2/_catalog"
# curl -u ${registry_cred_text} -k https://${MIRROR_REGISTRY_HOST}/v2/_catalog

readable_version=$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq .metadata.version)
echo "readable_version: $readable_version"

# MIRROR IMAGES

echo "running commad: oc adm release -a /tmp/new-pull-secret mirror --from=${RELEASE_IMAGE_LATEST} --to=${target_release_image_repo} --to-release-image=${target_release_image}"
oc adm release -a '/tmp/new-pull-secret' mirror --insecure=true --max-per-registry=2 \
 --from=${RELEASE_IMAGE_LATEST} \
 --to=${target_release_image_repo} \
 --to-release-image=${target_release_image} | tee "${mirror_output}"


# grep -B 1 -A 10 "kind: ImageContentSourcePolicy" ${mirror_output}
grep -A 6 "imageContentSources" ${mirror_output} > "${SHARED_DIR}/install-config-image.patch.yaml"

echo "install-config-image.patch.yaml:"
cat "${SHARED_DIR}/install-config-image.patch.yaml"

/tmp/yq m -x -i "${CONFIG}" "${SHARED_DIR}/install-config-image.patch.yaml"

# CA
cat <<EOF >"${SHARED_DIR}/install-config-client-ca.patch.yaml"
additionalTrustBundle: |
`sed 's/^/  /g' "${CLUSTER_PROFILE_DIR}/client_ca_crt"`
EOF

/tmp/yq m -x -i "${CONFIG}" "${SHARED_DIR}/install-config-client-ca.patch.yaml"

subnets="$(cat "${SHARED_DIR}/allsubnetids")"
echo "subnets: ${subnets}"

CONFIG_PRIVATE_CLUSTER="${SHARED_DIR}/install-config-private.patch.yaml"
cat > "${CONFIG_PRIVATE_CLUSTER}" << EOF
publish: Internal
platform:
  aws:
    subnets: ${subnets}
EOF
/tmp/yq m -x -i "${CONFIG}" "${CONFIG_PRIVATE_CLUSTER}"

# zones were added in ipi-conf-aws
# but when using byo VPC, we cannot ensure zones and subnets match
# so, remove it for private cluster
# TODO: ensure selected zones and subnet match
/tmp/yq d -i "${CONFIG}" 'controlPlane.platform.aws.zones'
/tmp/yq d -i "${CONFIG}" 'compute[0].platform.aws.zones'

echo "install-config.yaml:"
cat "${CONFIG}"

cp "${SHARED_DIR}"/* "${ARTIFACT_DIR}/"