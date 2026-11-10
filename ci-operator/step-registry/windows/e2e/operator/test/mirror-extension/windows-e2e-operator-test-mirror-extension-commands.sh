#!/bin/bash

# Mirror ci-operator's resolved EXTENSION_IMAGE to the bastion registry named by
# SHARED_DIR/mirror_registry_url. Combine profile, mirror and build-farm auth;
# verify the destination before publishing mirrored_extension_image and the
# mode-600 openshift-tests-registry-auth handoff. EXIT removes private temporary
# auth and, unless publication completed, both handoffs; failures stop the step.

set -o nounset
set -o errexit
set -o pipefail

registry_auth="${SHARED_DIR}/openshift-tests-registry-auth"
rm -f "${SHARED_DIR}/mirrored_extension_image" "${registry_auth}"
: "${EXTENSION_IMAGE:?EXTENSION_IMAGE must be resolved by ci-operator}"
mirror_registry_host=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
: "${mirror_registry_host:?Mirror registry host must not be empty}"
mirrored_extension_image="${mirror_registry_host}/pipeline:wmco-tests-extension"
umask 077
auth_dir=$(mktemp -d)
handoff_ready=false
trap 'rm -rf "${auth_dir}"; if [[ "${handoff_ready}" != true ]]; then rm -f "${SHARED_DIR}/mirrored_extension_image" "${registry_auth}"; fi' EXIT
new_pull_secret="${auth_dir}/pull-secret"
jq --arg host "${mirror_registry_host}" \
    --rawfile credentials /var/run/vault/mirror-registry/registry_creds \
    '.auths[$host] = {auth: ($credentials | split("\n")[0] | @base64)}' \
    "${CLUSTER_PROFILE_DIR}/pull-secret" >"${new_pull_secret}"
KUBECONFIG="" oc registry login --to "${new_pull_secret}"

retries=0
# Retry the exact source image, retaining all architectures; never publish a
# handoff after exhausted retries or failed destination inspection.
until oc image mirror "${EXTENSION_IMAGE}" "${mirrored_extension_image}" --insecure=true -a "${new_pull_secret}" --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'; do
    if [[ ${retries} -eq 5 ]]; then
        echo "Max retries reached mirroring OTE image, exiting"
        exit 1
    fi
    sleep 5
    ((retries += 1))
done

oc image info "${mirrored_extension_image}" --insecure=true -a "${new_pull_secret}" >/dev/null
cp "${new_pull_secret}" "${registry_auth}"
chmod 600 "${registry_auth}"
printf '%s\n' "${mirrored_extension_image}" >"${SHARED_DIR}/mirrored_extension_image"
handoff_ready=true
