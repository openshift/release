#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

rm -f "${SHARED_DIR}/mirrored_extension_image"
: "${EXTENSION_IMAGE:?EXTENSION_IMAGE must be resolved by ci-operator}"
mirror_registry_host=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
: "${mirror_registry_host:?Mirror registry host must not be empty}"
mirrored_extension_image="${mirror_registry_host}/pipeline:wmco-tests-extension"
umask 077
auth_dir=$(mktemp -d)
trap 'rm -rf "${auth_dir}"' EXIT
new_pull_secret="${auth_dir}/pull-secret"
jq --arg host "${mirror_registry_host}" \
    --rawfile credentials /var/run/vault/mirror-registry/registry_creds \
    '.auths[$host] = {auth: ($credentials | split("\n")[0] | @base64)}' \
    "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"
KUBECONFIG="" oc registry login --to "${new_pull_secret}"

retries=0
until oc image mirror "${EXTENSION_IMAGE}" "${mirrored_extension_image}" --insecure=true -a "${new_pull_secret}" --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'; do
    if [[ ${retries} -eq 5 ]]; then
        echo "Max retries reached mirroring OTE image, exiting"
        exit 1
    fi
    sleep 5
    ((retries+=1))
done

oc image info "${mirrored_extension_image}" --insecure=true -a "${new_pull_secret}" > /dev/null
printf '%s\n' "${mirrored_extension_image}" > "${SHARED_DIR}/mirrored_extension_image"

# openshift-tests extracts extension binaries in a later container and cannot
# read this step's temporary auth file. Preserve the verified credentials and
# expose them through the environment file sourced by openshift-e2e-test.
registry_auth="${SHARED_DIR}/openshift-tests-registry-auth"
cp "${new_pull_secret}" "${registry_auth}"
chmod 600 "${registry_auth}"
cluster_debug_tools_env="${SHARED_DIR}/cluster-debug-tools.env"
if [[ -f "${cluster_debug_tools_env}" ]]; then
    grep -v '^export REGISTRY_AUTH_FILE=' "${cluster_debug_tools_env}" > "${new_pull_secret}.env" || true
else
    : > "${new_pull_secret}.env"
fi
printf 'export REGISTRY_AUTH_FILE="%s"\n' "${registry_auth}" >> "${new_pull_secret}.env"
mv "${new_pull_secret}.env" "${cluster_debug_tools_env}"
chmod 600 "${cluster_debug_tools_env}"
