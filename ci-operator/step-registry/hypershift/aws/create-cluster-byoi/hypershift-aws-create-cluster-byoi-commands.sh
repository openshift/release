#!/bin/bash

set -exuo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com

HC_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
fi

DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
CLUSTER_NAME="$(cat ${SHARED_DIR}/cluster-name)"
INFRA_JSON="${SHARED_DIR}/aws_infra_output.json"
IAM_JSON="${SHARED_DIR}/aws_iam_output.json"

# Verify required files exist
if [[ ! -f "${INFRA_JSON}" ]]; then
  echo "ERROR: Infrastructure output file not found at ${INFRA_JSON}"
  exit 1
fi

if [[ ! -f "${IAM_JSON}" ]]; then
  echo "ERROR: IAM output file not found at ${IAM_JSON}"
  exit 1
fi

echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME} with pre-created infrastructure"
echo "Region: ${HC_REGION}"
echo "Base domain: ${DOMAIN}"
echo "Release image: ${RELEASE_IMAGE}"

# Create cluster using pre-created infrastructure and IAM resources
COMMAND=(
  /usr/bin/hypershift create cluster aws
  --name "${CLUSTER_NAME}"
  --infra-json "${INFRA_JSON}"
  --iam-json "${IAM_JSON}"
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}"
  --instance-type "${HYPERSHIFT_INSTANCE_TYPE}"
  --base-domain "${DOMAIN}"
  --endpoint-access "${ENDPOINT_ACCESS}"
  --region "${HC_REGION}"
  --control-plane-availability-policy "${HYPERSHIFT_CP_AVAILABILITY_POLICY}"
  --infra-availability-policy "${HYPERSHIFT_INFRA_AVAILABILITY_POLICY}"
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson
  --aws-creds="${AWS_GUEST_INFRA_CREDENTIALS_FILE}"
  --release-image "${RELEASE_IMAGE}"
  --annotations=hypershift.openshift.io/skip-release-image-validation=true
  --additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)"
)

# Execute cluster creation
"${COMMAND[@]}"

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}

echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

# Wait for cluster version rollout to complete
set +e
export CLUSTER_NAME
timeout 25m bash -c '
  until [[ "$(oc get -n clusters hostedcluster/${CLUSTER_NAME} -o jsonpath='"'"'{.status.version.history[?(@.state!="")].state}'"'"')" = "Completed" ]]; do
    sleep 15
  done
'

if [[ $? -ne 0 ]]; then
  cat << EOF > ${ARTIFACT_DIR}/junit_hosted_cluster.xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift install" tests="1" failures="1">
  <testcase name="hosted cluster version rollout succeeds">
    <failure message="hosted cluster version rollout never completed">
      <![CDATA[
error: hosted cluster version rollout never completed, dumping relevant hosted cluster condition messages
Degraded: $(oc get -n clusters hostedcluster/${CLUSTER_NAME} -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}')
ClusterVersionSucceeding: $(oc get -n clusters hostedcluster/${CLUSTER_NAME} -o jsonpath='{.status.conditions[?(@.type=="ClusterVersionSucceeding")].message}')
      ]]>
    </failure>
  </testcase>
</testsuite>
EOF
  exit 1
else
  cat << EOF > ${ARTIFACT_DIR}/junit_hosted_cluster.xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift install" tests="1" failures="0">
  <testcase name="hosted cluster version rollout succeeds">
    <system-out>
      <![CDATA[
info: hosted cluster version rollout completed successfully
      ]]>
    </system-out>
  </testcase>
</testsuite>
EOF
fi

echo "$(date) HyperShift cluster ${CLUSTER_NAME} created successfully with separate infrastructure"
