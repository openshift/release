#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | jq -r ".digest")"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

function isPreVersion() {
  local version="$1"
  local required_ocp_version="$2"
  local isPre=0
  if [ -n "${version}" ] && [ "$(printf '%s\n' "${required_ocp_version}" "${version}" | sort --version-sort | head -n1)" = "${required_ocp_version}" ]; then
    isPre=1
  fi
  return $isPre
}

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"
echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
if [[ "${USE_ORIGINAL_OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" == "true" ]]; then
  ORIGINAL_OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=$(KUBECONFIG="" oc get is release -o jsonpath='{range .status.tags[*].items[*]}{.image}{" "}{.dockerImageReference}{"\n"}{end}' | grep "^$(echo "$OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE" | sed 's/.*@//')" | awk '{print $2}')
  echo "User want the original payload for cluster upgrade, overwrite OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE to ${ORIGINAL_OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
  export OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${ORIGINAL_OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}
fi

if [[ -z "$OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

# target release
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
echo "target_release_image_repo: $target_release_image_repo"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
KUBECONFIG="" oc registry login

run_command "which oc"
run_command "oc version --client"
oc_mirror_dir=$(mktemp -d)
pushd "${oc_mirror_dir}"
new_pull_secret="${oc_mirror_dir}/new_pull_secret"

# combine custom registry credential and default pull secret
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
cat "${CLUSTER_PROFILE_DIR}/pull-secret" | python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${MIRROR_REGISTRY_HOST}'"]={"auth":"'${registry_cred}'"};j["auths"]=a;print(json.dumps(j))' > "${new_pull_secret}"

oc_mirror_bin="oc-mirror"
run_command "'${oc_mirror_bin}' version --output=yaml"

# set the imagesetconfigure
image_set_config="image_set_config.yaml"
cat <<END | tee "${image_set_config}"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}
    graph: ${MIRROR_GRAPH_DATA}
END

# https://github.com/openshift/oc-mirror/blob/main/docs/usage.md#authentication
# oc-mirror only respect ~/.docker/config.json -> ${XDG_RUNTIME_DIR}/containers/auth.json
mkdir -p "${XDG_RUNTIME_DIR}/containers/"
cp -rf "${new_pull_secret}" "${XDG_RUNTIME_DIR}/containers/auth.json"

unset REGISTRY_AUTH_PREFERENCE

payload_signed="true"
check_signed "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" || payload_signed="false"

mirrorCmd="'${oc_mirror_bin}' -c ${image_set_config} docker://${target_release_image_repo} --dest-tls-verify=false --v2 --workspace file://${oc_mirror_dir}"

# ref OCPBUGS-56009
ocp_version=$(oc adm release info --registry-config ${CLUSTER_PROFILE_DIR}/pull-secret ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE} -o jsonpath='{.metadata.version}' | cut -d. -f 1,2)
if ! isPreVersion "${ocp_version}" "4.19" && [[ "${payload_signed}" == "false" ]] ; then
    mirrorCmd="${mirrorCmd} --ignore-release-signature"
fi

# execute the oc-mirror command
run_command "${mirrorCmd}"

# Save output from oc-mirror
result_folder="${oc_mirror_dir}/working-dir"
run_command "find '${result_folder}' | sort"

export KUBECONFIG=${SHARED_DIR}/kubeconfig

idms_file="${result_folder}/cluster-resources/idms-oc-mirror.yaml"
itms_file="${result_folder}/cluster-resources/itms-oc-mirror.yaml"

if [ ! -s "${idms_file}" ]; then
    echo "${idms_file} not found, exit..."
    exit 1
else
    run_command "cat '${idms_file}'"
    upgrade_idms_file="${SHARED_DIR}/upgrade_$(basename ${idms_file})"
    run_command "cp -rf '${idms_file}' ${upgrade_idms_file}"
    echo "=== checking the difference of idms yamls generated for install and upgrade ==="
    install_idms_file="${SHARED_DIR}/idms-oc-mirror.yaml"
    diff_ret=0
    run_command "diff <(grep -A 1000 'imageDigestMirrors:' '${install_idms_file}') <(grep -A 1000 'imageDigestMirrors:' '${upgrade_idms_file}')" || diff_ret="$?"
    if [[ ${diff_ret} -ne 0 ]]; then
        echo "idms changed, applying the new one"
        run_command "oc apply -f ${upgrade_idms_file}"
    fi
fi

if [ -s "${itms_file}" ]; then
    echo "${itms_file} found"
    run_command "cat '${itms_file}'"
    upgrade_itms_file="${SHARED_DIR}/upgrade_$(basename ${itms_file})"
    run_command "cp -rf '${itms_file}' ${upgrade_itms_file}"
    echo "=== checking the difference of itms yamls generated for install and upgrade ==="
    install_itms_file="${SHARED_DIR}/itms-oc-mirror.yaml"
    diff_ret=0
    run_command "diff <(grep -A 1000 'imageTagMirrors:' '${install_itms_file}') <(grep -A 1000 'imageTagMirrors:' '${upgrade_itms_file}')" || diff_ret="$?"
    if [[ ${diff_ret} -ne 0 ]]; then
        echo "itms changed, applying the new one"
        run_command "oc apply -f ${upgrade_itms_file}"
    fi
fi

if [[ "${MIRROR_GRAPH_DATA}" == "true" ]]; then
    us_file="${result_folder}/cluster-resources/updateService.yaml"
    if [ ! -s "${us_file}" ]; then
        echo "${us_file} not found, exit..."
        exit 1
    else
        run_command "cat '${us_file}'"
        run_command "cp -rf '${us_file}' ${SHARED_DIR}"
    fi
    
    if [[ "${payload_signed}" == "false" ]]; then
        echo "You're mirroring an unsigned images, don't apply signature"
    else
        echo "You're mirroring a signed images, will apply signature"
        # oc-mirror v2 support mirror with signatures from 4.18
        sig_file="${result_folder}/cluster-resources/signature-configmap.json"
        if [[ ! -s "${sig_file}" ]]; then
            echo "signatures not found, exit..."
            exit 1
        fi
        run_command "cat '${sig_file}'"
        echo ""
        run_command "oc apply -f '${sig_file}'"
    fi
fi

# Ending
rm -f "${new_pull_secret}"
