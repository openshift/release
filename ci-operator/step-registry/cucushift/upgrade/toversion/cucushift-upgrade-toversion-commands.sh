#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo "Generating the Junit for upgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="0">
  <testcase classname="cluster upgrade" name="upgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="1">
  <testcase classname="cluster upgrade" name="upgrade should succeed">
    <failure message="">openshift cluster upgrade failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function extract_ccoctl(){
    local payload_image image_arch cco_image
    local retry=5
    local tmp_ccoctl="/tmp/upgtool"
    mkdir -p ${tmp_ccoctl}
    export PATH=/tmp:${PATH}

    echo -e "Extracting ccoctl\n"
    payload_image="${TARGET}"
    set -x
    image_arch=$(oc adm release info ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret" -o jsonpath='{.config.architecture}')
    if [[ "${image_arch}" == "arm64" ]]; then
        echo "The target payload is arm64 arch, trying to find out a matched version of payload image on amd64"
        if [[ -n ${RELEASE_IMAGE_TARGET:-} ]]; then
            payload_image=${RELEASE_IMAGE_TARGET}
            echo "Getting target release image from RELEASE_IMAGE_TARGET: ${payload_image}"
        elif env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc get istag "release:target" -n ${NAMESPACE} &>/dev/null; then
            payload_image=$(env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc -n ${NAMESPACE} get istag "release:target" -o jsonpath='{.tag.from.name}')
            echo "Getting target release image from build farm imagestream: ${payload_image}"
        fi
    fi
    set +x
    cco_image=$(oc adm release info --image-for='cloud-credential-operator' ${payload_image} -a "${CLUSTER_PROFILE_DIR}/pull-secret") || return 1
    while ! (env "NO_PROXY=*" "no_proxy=*" oc image extract $cco_image --path="/usr/bin/ccoctl:${tmp_ccoctl}" -a "${CLUSTER_PROFILE_DIR}/pull-secret");
    do
        echo >&2 "Failed to extract ccoctl binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_ccoctl}/ccoctl /tmp -f
    if [[ ! -e /tmp/ccoctl ]]; then
        echo "No ccoctl tool found!" && return 1
    else
        chmod 775 /tmp/ccoctl
    fi
    export PATH="$PATH"
}

function update_cloud_credentials_oidc(){
    local platform preCredsDir tobeCredsDir tmp_ret

    platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
    preCredsDir="/tmp/pre-include-creds"
    tobeCredsDir="/tmp/tobe-include-creds"
    mkdir "${preCredsDir}" "${tobeCredsDir}"
    # Extract all CRs from live cluster with --included
    if ! oc adm release extract --to "${preCredsDir}" --included --credentials-requests; then
        echo "Failed to extract CRs from live cluster!" && exit 1
    fi
    if ! oc adm release extract --to "${tobeCredsDir}" --included --credentials-requests "${TARGET}"; then
        echo "Failed to extract CRs from tobe upgrade release payload!" && exit 1
    fi

    # TODO: add gcp and azure
    # Update iam role with ccoctl based on tobeCredsDir
    tmp_ret=0
    diff -r "${preCredsDir}" "${tobeCredsDir}" || tmp_ret=1
    if [[ ${tmp_ret} != 0 ]]; then
        toManifests="/tmp/to-manifests"
        mkdir "${toManifests}"
        case "${platform}" in
        "AWS")
            if [[ ! -e ${SHARED_DIR}/aws_oidc_provider_arn ]]; then
                echo "No aws_oidc_provider_arn file in SHARED_DIR" && exit 1
            else
                export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
                infra_name=${NAMESPACE}-${UNIQUE_HASH}
                oidc_provider=$(head -n1 ${SHARED_DIR}/aws_oidc_provider_arn)
                extract_ccoctl
                if ! ccoctl aws create-iam-roles --name="${infra_name}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="${tobeCredsDir}" --identity-provider-arn="${oidc_provider}" --output-dir="${toManifests}"; then
                    echo "Failed to update iam role!" && exit 1
                fi
                if [[ "$(ls -A ${toManifests}/manifests)" ]]; then
                    echo "Apply the new credential secrets."
                    oc apply -f "${toManifests}/manifests"
                fi
            fi
            ;;
        *)
           echo "to be supported platform: ${platform}" 
           ;;
        esac
    fi
}

# Add cloudcredential.openshift.io/upgradeable-to: <version_number> to cloudcredential cluster when cco mode is manual or the case in OCPQE-19413
function cco_annotation(){
    if (( SOURCE_MINOR_VERSION == TARGET_MINOR_VERSION )) || (( SOURCE_MINOR_VERSION < 8 )); then
        echo "CCO annotation change is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local cco_mode; cco_mode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}')"
    local platform; platform="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')"
    if [[ ${cco_mode} == "Manual" ]]; then
        echo "CCO annotation change is required in Manual mode"
    elif [[ -z "${cco_mode}" || ${cco_mode} == "Mint" ]]; then
        if [[ "${SOURCE_MINOR_VERSION}" == "14" && ${platform} == "GCP" ]] ; then
            echo "CCO annotation change is required in default or Mint mode on 4.14 GCP cluster"
        else
            echo "CCO annotation change is not required in default or Mint mode on 4.${SOURCE_MINOR_VERSION} ${platform} cluster"
            return 0
        fi
    else
        echo "CCO annotation change is not required in ${cco_mode} mode"
        return 0
    fi

    echo "Require CCO annotation change"
    local wait_time_loop_var=0; to_version="$(echo "${TARGET_VERSION}" | cut -f1 -d-)"
    oc patch cloudcredential.operator.openshift.io/cluster --patch '{"metadata":{"annotations": {"cloudcredential.openshift.io/upgradeable-to": "'"${to_version}"'"}}}' --type=merge

    echo "CCO annotation patch gets started"

    echo -e "sleep 5 min wait CCO annotation patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "MissingUpgradeableAnnotation"; then
            echo -e "CCO annotation patch PASSED\n"
            return 0
        else
            echo -e "CCO annotation patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for CCO annotation completing, exiting" && return 1
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response try max_retries
    if [[ "${TARGET}" =~ "@sha256:" ]]; then
        digest="$(echo "${TARGET}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${TARGET}" -o json | jq -r ".digest")"
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
        echo "${TARGET} is signed" && return 0
    else
        echo "Seem like ${TARGET} is not signed" && return 1
    fi
}

# Check if admin ack is required before upgrade
function admin_ack() {
    if (( SOURCE_MINOR_VERSION == TARGET_MINOR_VERSION )) || (( SOURCE_MINOR_VERSION < 8 )); then
        echo "Admin ack is not required in either z-stream upgrade or 4.7 and earlier" && return
    fi

    local out; out="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r ".data")"
    if [[ ${out} != *"ack-4.${SOURCE_MINOR_VERSION}"* ]]; then
        echo "Admin ack not required: ${out}" && return
    fi

    echo "Require admin ack:\n ${out}"
    local wait_time_loop_var=0 ack_data

    ack_data="$(echo "${out}" | jq -r "keys[]")"
    for ack in ${ack_data};
    do
        # e.g.: ack-4.12-kube-1.26-api-removals-in-4.13
        if [[ "${ack}" == *"ack-4.${SOURCE_MINOR_VERSION}"* ]]
        then
            echo "Admin ack patch data is: ${ack}"
            oc -n openshift-config patch configmap admin-acks --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done
    echo "Admin-acks patch gets started"

    echo -e "sleep 5 min wait admin-acks patch to be valid...\n"
    while (( wait_time_loop_var < 5 )); do
        sleep 1m
        echo -e "wait_time_passed=${wait_time_loop_var} min.\n"
        if ! oc adm upgrade | grep "AdminAckRequired"; then
            echo -e "Admin-acks patch PASSED\n"
            return 0
        else
            echo -e "Admin-acks patch still in processing, waiting...\n"
        fi
        (( wait_time_loop_var += 1 ))
    done
    if (( wait_time_loop_var >= 5 )); then
        echo >&2 "Timed out waiting for admin-acks completing, exiting" && return 1
    fi
}

# judge if upgrade with --to or --to-latest cmd
# set correct target_version for the upgrade
function set_target_and_upgrade_cmd(){
    mapfile -t available_versions < <(echo "$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version')")
    if [[ -z "${available_versions[*]}" ]]; then
        echo "No recommended update available!"
        exit 1
    fi
    # x.y.z: run upgrade with "oc adm upgrade --to x.y.z";
    # By default we ENABLE_OTA_TEST: OCP-23799
    if [[ -n "${UPGRADE_TO_VERSION}" ]] && [[ "${UPGRADE_TO_VERSION}" != "latest" ]]; then
        valid_target="false"
        # check if x.y.z is in available_versions, if not, it's invalid target with --to.
        for version in ${available_versions[*]}; do
            if [[ "${UPGRADE_TO_VERSION}" == "${version}" ]]; then
                TARGET_VERSION="${UPGRADE_TO_VERSION}"
                valid_target="true"
                upgrade_cmd="oc adm upgrade --to ${TARGET_VERSION}"
                break
            fi
        done
        if [[ "${valid_target}" == "false" ]]; then
            echo "Specified target version ${UPGRADE_TO_VERSION} is not in recommended update, upgrade will not continue!"
            exit 1
        fi
    # get target_version from available updates
    else
        TARGET_VERSION=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version'|sort|tail -n1)
        # there will be three types version in candidate channel:4.15.0-ec1,4.15.0-rc1,4.15.0
        # when there are all above, sort will return 4.15.0-rc1 as latest(unexpected, should be 4.15.0),
        # when there is both 4.15.0 and 4.15.0-rc1, sort will return 4.15.0-rc1 as latest(unexpected, should be 4.15.0),
        # when there is both 4.15.0-rc1 and 4.15.0-ec1, sort will return 4.15.0-rc1 as latest(expected),
        # there will not be 4.15.0 and 4.15.0-ec1 only, ignore
        # so here we need correct unexpected latest with 4.15.0
        if [[ "${TARGET_VERSION}" =~ "-" ]]; then
            expected_target="${TARGET_VERSION%-*}"
            for version in ${available_versions[*]}; do
                if [[ "${version}" == "${expected_target}" ]]; then
                    TARGET_VERSION="${expected_target}"
                    break
                fi
            done
        fi
        # latest: run upgrade with "oc adm upgrade --to-latest";
        if [[ "${UPGRADE_TO_VERSION}" == "latest" ]]; then
            upgrade_cmd="oc adm upgrade --to-latest"
        # "": run upgrade with "oc adm upgrade --to $latest_version_in_available_update"
        else
            upgrade_cmd="oc adm upgrade --to ${TARGET_VERSION}"
        fi
    fi

    TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
    TARGET=$(oc get clusterversion version -o json| jq -r --arg z "${TARGET_VERSION}" '.status.availableUpdates[]? | select(.version==$z).image')
    if [[ "${TARGET}" == null ]] || [[ -z "${TARGET}" ]]; then
        echo "The target version ${TARGET_VERSION} is a bad update without image!"
        exit 1
    fi
    export TARGET_MINOR_VERSION
    export TARGET_VERSION
    export TARGET
    echo "Target release version is: ${TARGET_VERSION}"
}

# Monitor the upgrade status
function check_upgrade_status() {
    local wait_upgrade="${TIMEOUT}" out avail progress
    echo "Starting the upgrade checking on $(date "+%F %T")"
    while (( wait_upgrade > 0 )); do
        sleep 5m
        wait_upgrade=$(( wait_upgrade - 5 ))
        if ! ( run_command "oc get clusterversion" ); then
            continue
        fi
        if ! out="$(oc get clusterversion --no-headers)"; then continue; fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${TARGET_VERSION}" ]]; then
            echo -e "Upgrade succeed on $(date "+%F %T")\n\n"
            return 0
        fi
    done
    if [[ ${wait_upgrade} -le 0 ]]; then
        echo -e "Upgrade timeout on $(date "+%F %T"), exiting\n" && return 1
    fi
}

# Check version, state in history
function check_history() {
    local version state
    version=$(oc get clusterversion/version -o jsonpath='{.status.history[0].version}')
    state=$(oc get clusterversion/version -o jsonpath='{.status.history[0].state}')
    if [[ ${version} == "${TARGET_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now upgraded to ${TARGET_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster upgrade to ${TARGET_VERSION} failed, current version is ${version}, exiting" && return 1
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"

export DUMMY_TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
# we need this DUMMY_TARGET_VERSION from ci config to download oc and do some pre-check
DUMMY_TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${DUMMY_TARGET}" --output=json | jq -r '.metadata.version')"
echo "Target version of ci config is: ${DUMMY_TARGET_VERSION}"

SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
export SOURCE_VERSION
export SOURCE_MINOR_VERSION
echo "Source release version is: ${SOURCE_VERSION}"

x_ver=$( echo "${DUMMY_TARGET_VERSION}" | cut -f1 -d. )
y_ver=$( echo "${DUMMY_TARGET_VERSION}" | cut -f2 -d. )
ver="${x_ver}.${y_ver}"
retry=3
while (( retry > 0 ));do
    recommends=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version'| xargs)
    if [[ "${recommends}" == "null" ]] || [[ "${recommends}" != *"${ver}"* ]]; then
	retry=$((retry - 1))
        sleep 60
        echo "No recommended update available! Retry..."
    else
        echo "Recommencded update: ${recommends}"
        break
    fi
done
if (( retry == 0 )); then
    echo "Timeout to get recommended update!" 
    exit 1
fi

set_target_and_upgrade_cmd
export FORCE_UPDATE="false"
if ! check_signed; then
    echo "You're updating to an unsigned images, you must override the verification using --force flag"
    FORCE_UPDATE="true"
else
    echo "You're updating to a signed images, so run the upgrade command without --force flag"
fi
if [[ "${FORCE_UPDATE}" == "false" ]]; then
    admin_ack
    cco_annotation
fi
if [[ "${UPGRADE_CCO_MANUAL_MODE}" == "oidc" ]]; then
    update_cloud_credentials_oidc
fi
run_command "${upgrade_cmd} --force=${FORCE_UPDATE}"
echo "Upgrading cluster to ${TARGET_VERSION} gets started..."
check_upgrade_status
check_history
