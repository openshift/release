#!/bin/bash

REGION="${LEASED_RESOURCE}"
CONFIG="${SHARED_DIR}/install-config.yaml"

function patch_endpoint()
{
  local service_name=$1
  local service_endpoint=$2
  local config_patch="${SHARED_DIR}/install-config-${service_name}.yaml.patch"
  if [ "$service_endpoint" == "DEFAULT_ENDPOINT" ]; then
    service_endpoint="https://${service_name}.${REGION}.amazonaws.com"
  fi
  cat > "${config_patch}" << EOF
platform:
  aws:
    serviceEndpoints:
    - name: ${service_name}
      url: ${service_endpoint}
EOF
  echo "Adding custom endpoint $service_name $service_endpoint"
  yq-go m -a -x -i "${CONFIG}" "${config_patch}"
}

## ec2
if [ -n "$SERVICE_ENDPOINT_EC2" ]; then
  patch_endpoint "ec2" $SERVICE_ENDPOINT_EC2
fi

## elasticloadbalancing
if [ -n "$SERVICE_ENDPOINT_ELB" ]; then
  patch_endpoint "elasticloadbalancing" $SERVICE_ENDPOINT_ELB
fi

## s3
if [ -n "$SERVICE_ENDPOINT_S3" ]; then
  patch_endpoint "s3" $SERVICE_ENDPOINT_S3
fi

## iam
if [ -n "$SERVICE_ENDPOINT_IAM" ]; then
  patch_endpoint "iam" $SERVICE_ENDPOINT_IAM
fi

## tagging
if [ -n "$SERVICE_ENDPOINT_TAGGING" ]; then
  patch_endpoint "tagging" $SERVICE_ENDPOINT_TAGGING
fi

## route53
if [ -n "$SERVICE_ENDPOINT_ROUTE53" ]; then
  patch_endpoint "route53" $SERVICE_ENDPOINT_ROUTE53
fi

## sts
if [ -n "$SERVICE_ENDPOINT_STS" ]; then
  patch_endpoint "sts" $SERVICE_ENDPOINT_STS
fi

## autoscaling
if [ -n "$SERVICE_ENDPOINT_AUTOSCALING" ]; then
  patch_endpoint "autoscaling" $SERVICE_ENDPOINT_AUTOSCALING
fi

## servicequotas
if [ -n "$SERVICE_ENDPOINT_SERVICEQUOTAS" ]; then
  patch_endpoint "servicequotas" $SERVICE_ENDPOINT_SERVICEQUOTAS
fi

## kms
if [ -n "$SERVICE_ENDPOINT_KMS" ]; then
  patch_endpoint "kms" $SERVICE_ENDPOINT_KMS
fi
