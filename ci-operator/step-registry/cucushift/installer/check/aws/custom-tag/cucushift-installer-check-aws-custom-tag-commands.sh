#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

CONFIG=${SHARED_DIR}/install-config.yaml
if [ ! -f "${CONFIG}" ] ; then
  echo "No install-config.yaml found, exit now"
  exit 1
fi

ret=0

#
# Check cluster resources
#
propagate_tags=$(yq-go r "${CONFIG}" 'platform.aws.propagateUserTags')
# Read install-config ready tags config
# Format:
# [
#   {
#     "key": "c",
#     "value": "c"
#   },
#   {
#     "key": "key-length-128-abcs123456789s123456789s123456789s123456789s123456789s123456789s123456789s123456789s123456789s123456789s123456789",
#     "value": "false"
#   }
# ]
install_config_tags=${ARTIFACT_DIR}/install_config_tags.json
yq-go r "${CONFIG}" platform.aws.userTags -j | jq 'to_entries[] | {(.key):(.value|tostring)}' | jq -s 'add' | jq 'to_entries | sort_by(.key)' > ${install_config_tags}

if [[ ${propagate_tags} == "true" ]]; then
  cluster_inf_tags=${ARTIFACT_DIR}/cluster_inf_tags.json
  oc get infrastructures.config.openshift.io -o json | jq -r '.items[].status.platformStatus.aws.resourceTags | sort_by(.key)' > ${cluster_inf_tags}
  
  if [[ $(jq -c . $cluster_inf_tags | md5sum | cut -d ' ' -f1) != $(jq -c . $install_config_tags | md5sum | cut -d ' ' -f1) ]]; then
    echo "FAIL: Cluster infrastructures tags"
    ret=$((ret+1))
  else
    echo "PASS: Cluster infrastructures tags"
  fi

  oc -n openshift-ingress get svc/router-default -o json | jq -r '.metadata.annotations."service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags"'
fi

#
# Check AWS resources
#
function add_tag_to_filter_param() {
    local k="$1"
    local v="$2"
    local out="$3"
    if [ ! -e "$out" ]; then
        echo -n '[]' > "$out"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"Key":$k, "Values":[$v]}]' "$out")" > "$out"
}

function generte_tag_filter_param()
{
  local tags=$1
  local out=$2
  local k
  local v
  while IFS= read -r kv
  do
    k=$(echo $kv | cut -d':' -f1)
    v=$(echo $kv | cut -d':' -f2- | xargs) # xargs is used for trim begin/end spaces
    add_tag_to_filter_param "$k" "$v" $out
  done < "${tags}"
}

tags_output=${ARTIFACT_DIR}/user_tags.txt
tags_filter_param=${ARTIFACT_DIR}/tags_filter_param.json
yq-go r "${CONFIG}" platform.aws.userTags > ${tags_output}

# Tags for common AWS resources
generte_tag_filter_param "${tags_output}" "${tags_filter_param}"

# # Tags for s3 objects
# # Due to a limit of 10 tags on S3 Bucket Objects
# #   only the first eight lexicographically sorted tags will be applied to the bootstrap ignition object, 
# #   which is a temporary resource only used during installation
# tags_output_s3=${ARTIFACT_DIR}/user_tags_s3.txt
# head -n 8 ${tags_output} > ${tags_output_s3}

# tags_filter_param_s3=${ARTIFACT_DIR}/tags_filter_param_s3.json
# generte_tag_filter_param "${tags_output_s3}" "${tags_filter_param_s3}"

resource_output=${ARTIFACT_DIR}/resources.txt
aws --region $REGION resourcegroupstaggingapi get-resources --tag-filters file://${tags_filter_param} | jq -r '.ResourceTagMappingList[].ResourceARN' | sort > $resource_output

function check_resource() {
    local regex="$1"
    if grep -qE "${regex}"  ${resource_output}; then
      echo "PASS: Resource ${regex}"
    else
      echo "FAIL: Resource ${regex}"
      ret=$((ret+1))
    fi
}

check_resource ".*instance/i-.*"
check_resource ".*network-interface/eni-.*"
check_resource ".*security-group/sg-.*"
check_resource ".*volume/vol-.*"
check_resource ".*loadbalancer/net/${INFRA_ID}-ext/.*"
check_resource ".*loadbalancer/net/${INFRA_ID}-int/.*"

check_resource ".*elastic-ip/eipalloc-.*"
check_resource ".*internet-gateway/igw-.*"
check_resource ".*loadbalancer/[0-9a-z]{32}"
check_resource ".*natgateway/nat-.*"
check_resource ".*route-table/rtb-.*"
check_resource ".*subnet/subnet-.*"
check_resource ".*vpc-endpoint/vpce-.*"
check_resource ".*vpc/vpc-.*"

# # Bootstrap
# # 4.15-
# # check_resource ".*${INFRA_ID}-bootstrap"
# # 4.16+
# # check_resource ".*openshift-bootstrap-data-${INFRA_ID}"


ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ocp_minor_version >= 16 )); then
  check_resource ".*targetgroup/additional-listener-.*"
  check_resource ".*targetgroup/apiserver-target-.*"
  check_resource ".*listener/net/${INFRA_ID}-ext/.*"
  check_resource ".*listener/net/${INFRA_ID}-int/.*"
fi

exit $ret
