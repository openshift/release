#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

mirror_output="${SHARED_DIR}/mirror_output"
install_config_icsp_patch="${SHARED_DIR}/install-config-icsp.yaml.patch"
icsp_file="${SHARED_DIR}/local_registry_icsp_file.yaml"
image_set_config="${SHARED_DIR}/image_set_config.yaml"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

readable_version=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
channel_name=$(echo ${readable_version} |awk -F '.' 'BEGIN{OFS="."} {print $1,$2}')
echo "readable_version: $readable_version"
echo "channel_name: $channel_name"

# check whether nightly payload.
if echo $readable_version |grep "nightly"; then
    echo "This is nigthly build, skip it."
    exit 1
fi
# target release
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
# ensure mirror release image by tag name, refer to https://github.com/openshift/oc/pull/1331
target_release_image="${target_release_image_repo}:${readable_version}"

echo "target_release_image: $target_release_image"
echo "target_release_image_repo: $target_release_image_repo"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG
oc registry login

# combine custom registry credential and default pull secret
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${XDG_RUNTIME_DIR}/new_pull_secret"

# set the imagesetconfigure
cat <<END |tee "${SHARED_DIR}/image_set_config.yaml"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
storageConfig:
  registry:
    imageURL: \${target_release_image}
    skipTLS: false
mirror:
  platform:
    channels:
      - name: stable-\${channel_name}
        minVersion: \${readable_version}
        maxVersion: \${readable_version}
END

# execute the oc-mirror command
oc mirror -c "${image_set_config}"   docker://"${target_release_image_repo}"  --dest-skip-tls  | tee "${mirror_output}"

tmp_mirror_output=$(cat ${mirror_output} | tail -n 1 | awk  '{print $NF}')
cat "${tmp_mirror_output}/imageContentSourcePolicy.yaml" > "${icsp_file}"
grep -A 6 "repositoryDigestMirrors" "${tmp_mirror_output}/imageContentSourcePolicy.yaml" > "${install_config_icsp_patch}"

echo "${install_config_icsp_patch}:"
cat "${install_config_icsp_patch}"
rm -f "${XDG_RUNTIME_DIR}/new_pull_secret"
