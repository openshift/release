#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

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

oc registry login
prefix="${NAMESPACE}-${JOB_NAME_HASH}-`echo $RANDOM`"
cr_yaml_d=`mktemp -d`
cr_json_d=`mktemp -d`
resources_d=`mktemp -d`
credentials_requests_files=`mktemp`
echo "extracting CR from image $RELEASE_IMAGE_LATEST"
oc version --client
REPO=$(oc -n ${NAMESPACE} get is release -o json | jq -r '.status.publicDockerImageRepository')
cmd="oc adm release extract ${REPO}:latest --credentials-requests --cloud=aws --to '$cr_yaml_d'"
oc image info ${RELEASE_IMAGE_LATEST}  || true
oc image info ${REPO}:latest || true
run_command "${cmd}" || exit 1

if [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" ]] &&  [[ ! -f ${SHARED_DIR}/manifest_feature_gate.yaml ]]; then
  remove_tech_preview_feature_from_manifests "${cr_yaml_d}" "TechPreviewNoUpgrade" || exit 1
fi

ls "${cr_yaml_d}" > "${credentials_requests_files}"


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


