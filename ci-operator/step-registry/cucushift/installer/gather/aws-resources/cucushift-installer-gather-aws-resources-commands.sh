#!/bin/bash
set -o nounset

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    REGION="${LEASED_RESOURCE}"
    INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)

    # VPC
    aws --region ${REGION} ec2 describe-vpcs --filters Name=tag:"kubernetes.io/cluster/${INFRA_ID}",Values=owned,shared > ${ARTIFACT_DIR}/vpc.json

    # Subnets
    vpc_id=$(jq -r '.Vpcs[].VpcId' ${ARTIFACT_DIR}/vpc.json)
    aws --region ${REGION} ec2 describe-subnets --filters Name=vpc-id,Values=${vpc_id} > ${ARTIFACT_DIR}/subnets.json

    # Instances
    aws --region ${REGION} ec2 describe-instances --filters Name=vpc-id,Values=${vpc_id} > ${ARTIFACT_DIR}/instances.json

    # Security Groups
    aws --region ${REGION} ec2 describe-security-groups --filters Name=vpc-id,Values=${vpc_id} > ${ARTIFACT_DIR}/security_groups.json

    # LBs
    aws --region ${REGION} elbv2 describe-load-balancers | jq -r --arg v $vpc_id '[.LoadBalancers[] | select(.VpcId==$v)]' > ${ARTIFACT_DIR}/elbv2.json
    # shellcheck disable=SC2046
    aws --region ${REGION} elbv2 describe-tags --resource-arns $(jq -r '.[].LoadBalancerArn' ${ARTIFACT_DIR}/elbv2.json) > ${ARTIFACT_DIR}/elbv2_tags.json

    aws --region ${REGION} elb describe-load-balancers | jq -r --arg v $vpc_id '[.LoadBalancerDescriptions[] | select(.VPCId==$v)]' > ${ARTIFACT_DIR}/elb.json
    # shellcheck disable=SC2046
    aws --region ${REGION} elb describe-tags --load-balancer-names $(jq -r '.[].LoadBalancerName' ${ARTIFACT_DIR}/elb.json) > ${ARTIFACT_DIR}/elb_tags.json

    # tags
    aws --region ${REGION} resourcegroupstaggingapi get-resources --tag-filters Key="kubernetes.io/cluster/${INFRA_ID}",Values=owned,shared > ${ARTIFACT_DIR}/resource_with_tag_kubernetes.json
    aws --region ${REGION} resourcegroupstaggingapi get-resources --tag-filters Key="sigs.k8s.io/cluster-api-provider-aws/cluster/${INFRA_ID}",Values=owned,shared > ${ARTIFACT_DIR}/resource_with_tag_capi.json
    ;;
*) 
    echo "Cluster type '${CLUSTER_TYPE}' is not supported, skip the step."
esac


