#!/bin/bash

set -exuo pipefail

# Use the nested management cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

# Generate unique cluster names from job ID
PUBLIC_NAME="$(echo -n "${PROW_JOB_ID}-pub"|sha256sum|cut -c-20)"
PRIVATE_NAME="$(echo -n "${PROW_JOB_ID}-prv"|sha256sum|cut -c-20)"
OAUTH_LB_NAME="$(echo -n "${PROW_JOB_ID}-oau"|sha256sum|cut -c-20)"

# Self-managed Azure credentials
AZURE_CREDS="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
AZURE_OIDC_ISSUER_URL="https://smazure.blob.core.windows.net/smazure"
AZURE_SA_TOKEN_ISSUER_KEY_PATH="/etc/hypershift-ci-jobs-self-managed-azure-e2e/serviceaccount-signer.private"
AZURE_WORKLOAD_IDENTITIES_FILE="/etc/hypershift-ci-jobs-self-managed-azure-e2e/workload-identities.json"

PULL_SECRET_PATH="/etc/ci-pull-credentials/.dockerconfigjson"

RELEASE_IMAGE="${RELEASE_IMAGE_LATEST}"
HC_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-centralus}"

# Read private NAT subnet ID from SHARED_DIR (written by setup-private-link step)
if [[ ! -s "${SHARED_DIR}/azure_private_nat_subnet_id" ]]; then
  echo "$(date) ERROR: azure_private_nat_subnet_id is required for the private guest cluster"
  exit 1
fi
AZURE_PRIVATE_NAT_SUBNET_ID="$(cat "${SHARED_DIR}/azure_private_nat_subnet_id")"

# External DNS domain flag (required for correct service publishing strategy,
# especially for Private topology clusters where the API server must use Route)
EXTERNAL_DNS_ARGS=""
if [[ -n "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" ]]; then
  EXTERNAL_DNS_ARGS="--external-dns-domain=${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
fi

# Marketplace image flags
ETCD_STORAGE_CLASS_ARGS=""
if [[ -n "${HYPERSHIFT_ETCD_STORAGE_CLASS:-}" ]]; then
  ETCD_STORAGE_CLASS_ARGS="--etcd-storage-class=${HYPERSHIFT_ETCD_STORAGE_CLASS}"
fi

MARKETPLACE_ARGS=""
if [[ -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER:-}" ]]; then
  MARKETPLACE_ARGS="--marketplace-publisher=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER} --marketplace-offer=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER}"
  if [[ -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU:-}" ]]; then
    MARKETPLACE_ARGS="${MARKETPLACE_ARGS} --marketplace-sku=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU}"
  elif [[ -f "${SHARED_DIR}/azure-marketplace-image-sku" ]]; then
    MARKETPLACE_ARGS="${MARKETPLACE_ARGS} --marketplace-sku=$(cat "${SHARED_DIR}/azure-marketplace-image-sku")"
  fi
  if [[ -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION:-}" ]]; then
    MARKETPLACE_ARGS="${MARKETPLACE_ARGS} --marketplace-version=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION}"
  elif [[ -f "${SHARED_DIR}/azure-marketplace-image-version" ]]; then
    MARKETPLACE_ARGS="${MARKETPLACE_ARGS} --marketplace-version=$(cat "${SHARED_DIR}/azure-marketplace-image-version")"
  fi
fi

# Common flags for all self-managed clusters
COMMON_FLAGS="--node-pool-replicas=${HYPERSHIFT_NODE_COUNT} \
  --base-domain=${HYPERSHIFT_BASE_DOMAIN} \
  --pull-secret=${PULL_SECRET_PATH} \
  --azure-creds=${AZURE_CREDS} \
  --location=${HC_LOCATION} \
  --release-image=${RELEASE_IMAGE} \
  --oidc-issuer-url=${AZURE_OIDC_ISSUER_URL} \
  --sa-token-issuer-private-key-path=${AZURE_SA_TOKEN_ISSUER_KEY_PATH} \
  --workload-identities-file=${AZURE_WORKLOAD_IDENTITIES_FILE} \
  --assign-service-principal-roles \
  --dns-zone-rg-name=os4-common \
  --generate-ssh \
  ${EXTERNAL_DNS_ARGS} \
  ${MARKETPLACE_ARGS} \
  ${ETCD_STORAGE_CLASS_ARGS}"

# Create public cluster
echo "$(date) Creating public self-managed cluster: ${PUBLIC_NAME}"
/usr/bin/hypershift create cluster azure \
  --name="${PUBLIC_NAME}" \
  ${COMMON_FLAGS} &
PUBLIC_PID=$!

# Create private cluster
PRIVATE_EXTRA="--endpoint-access-private-nat-subnet-id=${AZURE_PRIVATE_NAT_SUBNET_ID}"
echo "$(date) Creating private self-managed cluster: ${PRIVATE_NAME}"
/usr/bin/hypershift create cluster azure \
  --name="${PRIVATE_NAME}" \
  --endpoint-access=Private \
  ${COMMON_FLAGS} \
  ${PRIVATE_EXTRA} &
PRIVATE_PID=$!

# Create OAuth LoadBalancer cluster
echo "$(date) Creating OAuth LB self-managed cluster: ${OAUTH_LB_NAME}"
/usr/bin/hypershift create cluster azure \
  --name="${OAUTH_LB_NAME}" \
  --oauth-publishing-strategy=LoadBalancer \
  ${COMMON_FLAGS} &
OAUTH_LB_PID=$!

# Wait for create commands to complete
echo "$(date) Waiting for cluster create commands to finish..."
FAILED=0
wait ${PUBLIC_PID} || FAILED=1
echo "$(date) Public cluster create command completed"
wait ${PRIVATE_PID} || FAILED=1
echo "$(date) Private cluster create command completed"
wait ${OAUTH_LB_PID} || FAILED=1
echo "$(date) OAuth LB cluster create command completed"
if [[ ${FAILED} -ne 0 ]]; then
  echo "$(date) ERROR: One or more cluster create commands failed"
  exit 1
fi

# Patch the public cluster to set OperatorConfiguration for Ingress Operator.
# The v2 e2e test ValidateIngressOperatorConfiguration expects this to be set on
# public clusters (mirroring the BeforeApply hook used in the v1 CreateCluster test).
echo "$(date) Patching public cluster ${PUBLIC_NAME} with OperatorConfiguration..."
oc patch hostedcluster "${PUBLIC_NAME}" -n clusters --type=merge -p '
{
  "spec": {
    "operatorConfiguration": {
      "ingressOperator": {
        "endpointPublishingStrategy": {
          "type": "LoadBalancerService",
          "loadBalancer": {
            "scope": "Internal"
          }
        }
      }
    }
  }
}'
echo "$(date) Public cluster ${PUBLIC_NAME} patched with OperatorConfiguration"

# Wait for clusters to become available
echo "$(date) Waiting for public cluster to become available..."
oc wait --timeout=30m --for=condition=Available --namespace=clusters "hostedcluster/${PUBLIC_NAME}"
echo "$(date) Public cluster is available"

echo "$(date) Waiting for private cluster to become available..."
oc wait --timeout=30m --for=condition=Available --namespace=clusters "hostedcluster/${PRIVATE_NAME}"
echo "$(date) Private cluster is available"

echo "$(date) Waiting for OAuth LB cluster to become available..."
oc wait --timeout=30m --for=condition=Available --namespace=clusters "hostedcluster/${OAUTH_LB_NAME}"
echo "$(date) OAuth LB cluster is available"

# Wait for version rollout to complete on all clusters in parallel (via management API, same as AWS/GCP v2)
echo "$(date) Starting parallel version rollout checks..."
set +e

echo "$(date) Waiting for version rollout on ${PUBLIC_NAME}..."
CLUSTER_CHECK="${PUBLIC_NAME}" timeout 45m bash -c '
  until [[ "$(oc get -n clusters hostedcluster/${CLUSTER_CHECK} -o jsonpath='"'"'{.status.version.history[?(@.state!="")].state}'"'"')" = "Completed" ]]; do
    sleep 15
  done
' &
ROLLOUT_PID_PUB=$!

echo "$(date) Waiting for version rollout on ${PRIVATE_NAME}..."
CLUSTER_CHECK="${PRIVATE_NAME}" timeout 45m bash -c '
  until [[ "$(oc get -n clusters hostedcluster/${CLUSTER_CHECK} -o jsonpath='"'"'{.status.version.history[?(@.state!="")].state}'"'"')" = "Completed" ]]; do
    sleep 15
  done
' &
ROLLOUT_PID_PRV=$!

echo "$(date) Waiting for version rollout on ${OAUTH_LB_NAME}..."
CLUSTER_CHECK="${OAUTH_LB_NAME}" timeout 45m bash -c '
  until [[ "$(oc get -n clusters hostedcluster/${CLUSTER_CHECK} -o jsonpath='"'"'{.status.version.history[?(@.state!="")].state}'"'"')" = "Completed" ]]; do
    sleep 15
  done
' &
ROLLOUT_PID_OAU=$!

echo "$(date) Waiting for all version rollout checks to complete..."
FAILED_READY=0
for CLUSTER_PID in "${PUBLIC_NAME}:${ROLLOUT_PID_PUB}" "${PRIVATE_NAME}:${ROLLOUT_PID_PRV}" "${OAUTH_LB_NAME}:${ROLLOUT_PID_OAU}"; do
  CLUSTER="${CLUSTER_PID%%:*}"
  PID="${CLUSTER_PID##*:}"
  wait ${PID}
  ROLLOUT_RC=$?
  if [[ ${ROLLOUT_RC} -ne 0 ]]; then
    echo "$(date) ERROR: version rollout timed out for ${CLUSTER}"
    echo "--- Diagnostic dump for ${CLUSTER} ---"
    echo "HostedCluster conditions:"
    oc get -n clusters hostedcluster/${CLUSTER} -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' || true
    echo ""
    echo "NodePool status:"
    oc get -n clusters nodepool/${CLUSTER} -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' || true
    echo ""
    echo "Machines in clusters-${CLUSTER}:"
    oc get machines.cluster.x-k8s.io -n "clusters-${CLUSTER}" -o wide 2>/dev/null || true
    echo ""
    echo "AzureMachines in clusters-${CLUSTER}:"
    oc get azuremachines.infrastructure.cluster.x-k8s.io -n "clusters-${CLUSTER}" -o wide 2>/dev/null || true
    echo ""
    echo "Pods not ready in clusters-${CLUSTER}:"
    oc get pods -n "clusters-${CLUSTER}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
    echo "--- End diagnostic dump ---"
    cat << EOF > "${ARTIFACT_DIR}/junit_hosted_cluster_${CLUSTER}.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift install ${CLUSTER}" tests="1" failures="1">
  <testcase name="hosted cluster version rollout succeeds">
    <failure message="hosted cluster version rollout never completed">
      <![CDATA[
error: hosted cluster version rollout never completed for ${CLUSTER}
Degraded: $(oc get -n clusters hostedcluster/${CLUSTER} -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}')
ClusterVersionSucceeding: $(oc get -n clusters hostedcluster/${CLUSTER} -o jsonpath='{.status.conditions[?(@.type=="ClusterVersionSucceeding")].message}')
      ]]>
    </failure>
  </testcase>
</testsuite>
EOF
    FAILED_READY=1
  else
    echo "$(date) Version rollout completed for ${CLUSTER}"
    cat << EOF > "${ARTIFACT_DIR}/junit_hosted_cluster_${CLUSTER}.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hypershift install ${CLUSTER}" tests="1" failures="0">
  <testcase name="hosted cluster version rollout succeeds">
    <system-out>
      <![CDATA[
info: hosted cluster version rollout completed successfully for ${CLUSTER}
      ]]>
    </system-out>
  </testcase>
</testsuite>
EOF
  fi
done
set -e
if [[ ${FAILED_READY} -ne 0 ]]; then
  exit 1
fi

# Write cluster names to shared dir
echo "${PUBLIC_NAME}" > "${SHARED_DIR}/cluster-name-public"
echo "${PRIVATE_NAME}" > "${SHARED_DIR}/cluster-name-private"
echo "${OAUTH_LB_NAME}" > "${SHARED_DIR}/cluster-name-oauth-lb"

echo "$(date) All self-managed guest clusters are ready"
