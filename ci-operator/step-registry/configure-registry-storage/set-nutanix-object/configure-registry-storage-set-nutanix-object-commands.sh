#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script will set image registry to use nutanix object storage. 
# It need deploy against nutanix platform.
# Since nutanix object service still not support terraform, so we will use fixed bucket accordint to OCP version. And will clean up data on nutanix web console periodically.

export KUBECONFIG=${SHARED_DIR}/kubeconfig
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/xiuwang-nutanix-object-cred

AWS_ACCESS_KEY_ID=$(cat "${AWS_SHARED_CREDENTIALS_FILE}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2) && export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(cat "${AWS_SHARED_CREDENTIALS_FILE}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2) && export AWS_SECRET_ACCESS_KEY

if [[ ${AWS_ACCESS_KEY_ID} == "" ]] || [[ ${AWS_SECRET_ACCESS_KEY} == "" ]]; then
  echo "Did not find AWS credential, exit now"
  exit 1
fi

OCP_MINOR_VERSION=$(oc version | grep "Server Version" | cut -d '.' -f2)

# Create secret for s3 compatible storage
oc create secret generic image-registry-private-configuration-user  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=${AWS_ACCESS_KEY_ID}  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY=${AWS_SECRET_ACCESS_KEY} --namespace openshift-image-registry

# create configmap using nutanix object service CA
TRUSTED_CA="${CLUSTER_PROFILE_DIR}/nutanix-object-os-ca.pem"
if [[ -f "${TRUSTED_CA}" ]]; then
  oc create configmap custom-ca  --from-file=ca-bundle.crt=${TRUSTED_CA} -n openshift-config
else
  echo "Did not find compatible trusted ca"
  exit 1
fi
NUTANIX_OS_ENDPOINT=$(cat "${CLUSTER_PROFILE_DIR}/nutnaix_os_endpoint")
if [[ ${NUTANIX_OS_ENDPOINT} == "" ]]; then
  echo "Did not find nutanix os endpoint, exit now"
  exit 1
fi
NEW_OS_ENDPOINT="http://${NUTANIX_OS_ENDPOINT}"
# configure image registry to use nutanix object bucket
oc patch config.image/cluster -p '{"spec":{"managementState":"Managed","replicas":2,"storage":{"managementState":"Unmanaged","s3":{"bucket":"ocp-registry-4-'"${OCP_MINOR_VERSION}"'","region":"us-east-1","regionEndpoint":"'"${NEW_OS_ENDPOINT}"'","trustedCA":{"name":"custom-ca"}}}}}' --type=merge
# wait image registry to redeploy with new set
check_imageregistry_back_ready(){
  local result="" iter=10 period=60
  while [[ "${result}" != "TrueFalse" && $iter -gt 0 ]]; do
    sleep $period
    result=$(oc get co image-registry -o=jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}')
    (( iter -- ))
  done
  if [ "${result}" != "TrueFalse" ] ; then
    echo "Image registry failed to re-configure, please check the below resources"
    oc describe pods -l docker-registry=default -n openshift-image-registry
    oc get config.image/cluster -o yaml
    return 1
  else
    echo "Image registry configured nutanix object successfully"
    return 0
  fi
}
check_imageregistry_back_ready || exit 1
