#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function aws_create_policy()
{
    local aws_region=$1
    local policy_name=$2
    local policy_doc=$3
    local output_json="$4"

    cmd="aws --region $aws_region iam create-policy --policy-name ${policy_name} --policy-document '${policy_doc}' > '${output_json}'"
    run_command "${cmd}" || return 1
    return 0
}

function aws_create_user()
{
    local aws_region=$1
    local user_name=$2
    local policy_arn=$3
    local user_output=$4
    local access_key_output=$5
    
    # create user
    cmd="aws --region ${aws_region} iam create-user --user-name ${user_name} > '${user_output}'"
    run_command "${cmd}" || return 1

    # attach policy
    cmd="aws --region ${aws_region} iam attach-user-policy --user-name ${user_name} --policy-arn '${policy_arn}'"
    run_command "${cmd}" || return 1

    # create access key
    cmd="aws --region ${aws_region} iam create-access-key --user-name ${user_name} > '${access_key_output}'"
    run_command "${cmd}" || return 1

    return 0
}

function b64() { echo -n "${1}" | base64 ; }

function create_secret_file_for_aws()
{
    local ns=$1
    local name=$2
    local b64_key_id=$3
    local b64_key_sec=$4
    local output_file=$5
    cat <<EOF >${output_file}
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${ns}
data:
  aws_access_key_id: ${b64_key_id}
  aws_secret_access_key: ${b64_key_sec}
EOF
}

function remove_tech_preview_feature_from_manifests()
{
    local path="$1"
    local matched="$2"
    if [ ! -e "${path}" ]; then
        echo "[ERROR] CredentialsRequest manifests ${path} does not exist"
        return 2
    fi
    pushd "${path}"
    for i in *.yaml; do
        match_count=$(grep -c "${matched}" "${i}")
        if [ "$match_count" -ne '0' ]; then
            echo "[WARN] Remove CredentialsRequest ${i} which is a ${matched} CR"
            rm -f "${i}"
            [ $? -ne 0 ] && echo "[ERROR] error remove CredentialsRequest ${i}" && return 1
        fi
    done
    popd
    return 0
}

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

prefix="${NAMESPACE}-${UNIQUE_HASH}-`echo $RANDOM`"
cr_yaml_d=`mktemp -d`
cr_json_d=`mktemp -d`
resources_d=`mktemp -d`
credentials_requests_files=`mktemp`
echo "OC Version:"
export PATH=${CLI_DIR}:$PATH
which oc
oc version --client
oc adm release extract --help
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret
cmd="oc adm release extract --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --credentials-requests --cloud=aws --to '$cr_yaml_d' ${ADDITIONAL_OC_EXTRACT_ARGS}"
run_command "${cmd}" || exit 1
rm pull-secret
popd

echo "CR manifest files:"
ls "$cr_yaml_d"

if [[ "${EXTRACT_MANIFEST_INCLUDED}" != "true" ]] && [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" ]] &&  [[ ! -f ${SHARED_DIR}/manifest_feature_gate.yaml ]]; then
  remove_tech_preview_feature_from_manifests "${cr_yaml_d}" "TechPreviewNoUpgrade" || exit 1
fi

ls -p "${cr_yaml_d}"/*.yaml | awk -F'/' '{print $NF}' > "${credentials_requests_files}"


while IFS= read -r item
do
    #  Convert Credentials Request to json, and get name and namespace
    # 
    cr_yaml="${cr_yaml_d}/${item}"
    cr_json="${cr_json_d}/${item:0:-5}.json"
    yq-go r -j "${cr_yaml}" > "${cr_json}"

    name=$(cat "${cr_json}" | jq -r '.spec.secretRef.name')
    ns=$(cat "${cr_json}" | jq -r '.spec.secretRef.namespace')
    
    #  Create policy document
    # 
    policy_json="${resources_d}/policydoc_${ns}_${name}.json"
    echo "policy_json: $policy_json"
    cat "${cr_json}" \
        | sed 's/"action"/"Action"/g' \
        | sed 's/"effect"/"Effect"/g' \
        | sed 's/"policyCondition"/"Condition"/g' \
        | sed 's/"resource"/"Resource"/g' \
        | jq '{Version: "2012-10-17", Statement: .spec.providerSpec.statementEntries}' > "${policy_json}"
    policy_doc=$(cat "${policy_json}" | jq -c .)
    echo "policy_doc: $policy_doc"
    
    #  Create policy
    # 
    policy_name="${prefix}_policy_${ns}_${name}"
    echo "Creating policy ${policy_name}"
    output_policy="${resources_d}/policy_${policy_name}.json"
    aws_create_policy $REGION "${policy_name}" "${policy_doc}" "${output_policy}"
	
    policy_arn=$(cat "${output_policy}" | jq -r '.Policy.Arn')
    
    echo "${policy_arn}" >> "${SHARED_DIR}/aws_policy_arns"

    #  Create user
    # 
    user_name="${prefix}-${ns}"
    user_name="${user_name:0:61}-${RANDOM:0:2}"  # Member must have length less than or equal to 64
    echo "creating user: user_name: ${user_name} policy_arn: ${policy_arn}"
    output_users="${resources_d}/user_${user_name}.json"
    output_access_keys="${resources_d}/accesskey_${user_name}.json"
    aws_create_user $REGION "${user_name}" "${policy_arn}" "${output_users}" "${output_access_keys}"

    key_id=$(cat "${output_access_keys}" | jq -r '.AccessKey.AccessKeyId')
    key_sec=$(cat "${output_access_keys}" | jq -r '.AccessKey.SecretAccessKey')
    echo "${user_name}" >> "${SHARED_DIR}/aws_user_names"

    # Generate users manifests
    user_manifest="${SHARED_DIR}/manifest_user-${ns}-${name}-secret.yaml"
    echo "Generate users manifest file ${user_manifest}"
    create_secret_file_for_aws "$ns" "$name" "$(b64 ${key_id})" "$(b64 ${key_sec})" "${user_manifest}"
done < "${credentials_requests_files}"

exit 0


