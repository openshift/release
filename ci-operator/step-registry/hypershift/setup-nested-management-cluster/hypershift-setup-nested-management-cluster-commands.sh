#!/bin/bash

# Set cloud-specific defaults
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  export KUBECONFIG=/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig
  AZURE_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
  DEFAULT_BASE_DOMAIN=hcp-sm-azure.azure.devcluster.openshift.com
  HYPERSHIFT_INSTANCE_TYPE=Standard_D16s_v5
  HYPERSHIFT_AZURE_LOCATION=${HYPERSHIFT_AZURE_LOCATION:-centralus}
else
  AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
  DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com
  export KUBECONFIG=/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig

  if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
  fi
fi

DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}
DEFAULT_RELEASE_STREAM=4-stable
HYPERSHIFT_HC_RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:4.22.0-ec.5-multi}

CLUSTER_NAME_PREFIX="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-10)"
if [[ -n "${HYPERSHIFT_CLUSTER_ROLE}" ]]; then
  if [[ ! "${HYPERSHIFT_CLUSTER_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
    echo "HYPERSHIFT_CLUSTER_ROLE must contain only lowercase letters, digits, or hyphens" >&2
    exit 1
  fi
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-${HYPERSHIFT_CLUSTER_ROLE}-mgmt"
  MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  KUBECONFIG_OUTPUT="${SHARED_DIR}/kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  MANAGEMENT_CLUSTER_NAMESPACE_FILE="${SHARED_DIR}/management_cluster_namespace_${HYPERSHIFT_CLUSTER_ROLE}"
  MANAGEMENT_CLUSTER_NAME_FILE="${SHARED_DIR}/management_cluster_name_${HYPERSHIFT_CLUSTER_ROLE}"
  KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password_${HYPERSHIFT_CLUSTER_ROLE}"
  CONSOLE_URL_FILE="${SHARED_DIR}/console.url_${HYPERSHIFT_CLUSTER_ROLE}"
else
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-mgmt"
  MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
  KUBECONFIG_OUTPUT="${SHARED_DIR}/kubeconfig"
  MANAGEMENT_CLUSTER_NAMESPACE_FILE="${SHARED_DIR}/management_cluster_namespace"
  MANAGEMENT_CLUSTER_NAME_FILE="${SHARED_DIR}/management_cluster_name"
  KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password"
  CONSOLE_URL_FILE="${SHARED_DIR}/console.url"
fi

# Create the management cluster based on cloud provider
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  echo "Creating Azure management cluster ${CLUSTER_NAME} with ${HYPERSHIFT_NODE_COUNT} nodes"
  AZURE_WORKLOAD_IDENTITIES_FILE="/etc/hypershift-ci-jobs-self-managed-azure-e2e-mc/workload-identities.json"
  AZURE_OIDC_ISSUER_URL="https://smazure.blob.core.windows.net/smazure"
  AZURE_SA_TOKEN_ISSUER_KEY_PATH="/etc/hypershift-ci-jobs-self-managed-azure/serviceaccount-signer.private"
  # Ensure Premium SSD v2 StorageClass exists on the ops cluster for mgmt cluster etcd
  oc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-v2
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
  bin/hypershift create cluster azure \
    --annotations=hypershift.openshift.io/prow-job-id=${PROW_JOB_ID} \
    --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
    --azure-creds=${AZURE_GUEST_INFRA_CREDENTIALS_FILE} \
    --workload-identities-file=${AZURE_WORKLOAD_IDENTITIES_FILE} \
    --oidc-issuer-url=${AZURE_OIDC_ISSUER_URL} \
    --sa-token-issuer-private-key-path=${AZURE_SA_TOKEN_ISSUER_KEY_PATH} \
    --name=${CLUSTER_NAME} \
    --location=${HYPERSHIFT_AZURE_LOCATION} \
    --infra-id=${CLUSTER_NAME} \
    --base-domain=${DOMAIN} \
    --instance-type=${HYPERSHIFT_INSTANCE_TYPE} \
    --marketplace-publisher=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER} \
    --marketplace-offer=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER} \
    --marketplace-sku=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU} \
    --marketplace-version=${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION} \
    --service-cidr=172.29.0.0/16 \
    --cluster-cidr=10.124.0.0/14 \
    --node-pool-replicas=${HYPERSHIFT_NODE_COUNT} \
    --availability-zones=1,2,3 \
    --release-image=${HYPERSHIFT_HC_RELEASE_IMAGE} \
    --release-stream=${DEFAULT_RELEASE_STREAM} \
    --namespace=${HYPERSHIFT_NAMESPACE} \
    --assign-service-principal-roles \
    --dns-zone-rg-name=os4-common \
    --etcd-storage-class=managed-csi-premium-v2
else
  echo "Creating AWS management cluster ${CLUSTER_NAME} with $((${HYPERSHIFT_NODE_COUNT} * 3)) nodes"
  bin/hypershift create cluster aws \
    --annotations=hypershift.openshift.io/prow-job-id=${PROW_JOB_ID} \
    --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
    --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE} \
    --additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)" \
    --name=${CLUSTER_NAME} \
    --region=us-east-1 \
    --infra-id=${CLUSTER_NAME} \
    --base-domain=${DOMAIN} \
    --oidc-issuer-url=https://hypershift-ci-2-oidc.s3.us-east-1.amazonaws.com/shared-mgmt \
    --sa-token-issuer-private-key-path=/etc/hypershift-ci-jobs-awscreds/serviceaccount-signer.private \
    --instance-type=${HYPERSHIFT_INSTANCE_TYPE} \
    --zones=${HYPERSHIFT_ZONES} \
    --service-cidr=172.29.0.0/16 \
    --cluster-cidr=10.124.0.0/14 \
    --node-pool-replicas=${HYPERSHIFT_NODE_COUNT} \
    --node-selector=hypershift.openshift.io/control-plane=true \
    --release-image=${HYPERSHIFT_HC_RELEASE_IMAGE} \
    --release-stream=${DEFAULT_RELEASE_STREAM} \
    --public-only \
    --shared-role \
    --namespace=${HYPERSHIFT_NAMESPACE}
fi

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${HYPERSHIFT_NAMESPACE} hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"

# Data for cluster bot.
# The kubeadmin-password secret is reconciled only after the kas is available so giving a few seconds to avoid racing and move forward otherwise.
sleep 15
echo "Getting ${CLUSTER_NAME}-kubeadmin-password from namespace ${HYPERSHIFT_NAMESPACE}"
until \
  oc get secret -n "${HYPERSHIFT_NAMESPACE}" "${CLUSTER_NAME}-kubeadmin-password" 2> /dev/null; do
    echo "$(date --rfc-3339=seconds) kubeadmin password not yet available"
    sleep 5
done
oc get secret -n "${HYPERSHIFT_NAMESPACE}" "${CLUSTER_NAME}-kubeadmin-password" --template='{{.data.password}}' | base64 -d > "${KUBEADMIN_PASSWORD_FILE}"

bin/hypershift create kubeconfig --namespace=${HYPERSHIFT_NAMESPACE} --name=${CLUSTER_NAME} >"${MANAGEMENT_CLUSTER_KUBECONFIG}"
bin/hypershift create kubeconfig --namespace=${HYPERSHIFT_NAMESPACE} --name=${CLUSTER_NAME} >"${KUBECONFIG_OUTPUT}"
echo "${HYPERSHIFT_NAMESPACE}" > "${MANAGEMENT_CLUSTER_NAMESPACE_FILE}"
echo "${CLUSTER_NAME}" > "${MANAGEMENT_CLUSTER_NAME_FILE}"
echo "Waiting for clusteroperators to be ready"
export KUBECONFIG="${MANAGEMENT_CLUSTER_KUBECONFIG}"
until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null; do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    oc get clusterversion 2>/dev/null || true
    sleep 1s
done
# Data for cluster bot.
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${CONSOLE_URL_FILE}"

# Create a Premium SSD v2 storage class on Azure management clusters for etcd
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  echo "Creating managed-csi-premium-v2 StorageClass on management cluster"
  oc apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-v2
provisioner: disk.csi.azure.com
parameters:
  skuName: PremiumV2_LRS
  cachingMode: None
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
fi
