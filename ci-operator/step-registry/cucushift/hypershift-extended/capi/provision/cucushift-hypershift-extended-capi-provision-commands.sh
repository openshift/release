#!/bin/bash

set -xeuo pipefail

function retry() {
    local check_func=$1
    local max_retries=20
    local retry_delay=30
    local retries=0

    while (( retries < max_retries )); do
        if $check_func; then
            echo "check function finished successfully, return 0"
            return 0
        fi

        (( retries++ ))
        if (( retries < max_retries )); then
            echo "Retrying in $retry_delay seconds..."
            sleep $retry_delay
        fi
    done

    echo "Failed to run check function $1 after $max_retries attempts."
    return 1
}

function is_hcp_started() {
  cluster_res=$(rosa list clusters | grep ${CLUSTER_NAME})
  if [[ -n "$cluster_res" ]] ; then
    return 0
  fi
  return 1
}

# download clusterctl, clusterawsadm and envsubst
mkdir -p /tmp/bin
export PATH=/tmp/bin:$PATH
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.6.2/clusterctl-linux-amd64 -o /tmp/bin/clusterctl && \
    chmod +x /tmp/bin/clusterctl

curl -L https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/v2.4.0/clusterawsadm-linux-amd64 -o /tmp/bin/clusterawsadm && \
    chmod +x /tmp/bin/clusterawsadm

curl -L https://github.com/a8m/envsubst/releases/download/v1.4.2/envsubst-Linux-x86_64 -o /tmp/bin/envsubst && \
    chmod +x /tmp/bin/envsubst

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION=${REGION}
export AWS_PAGER=""

# default stage api url
ocm_api_url="https://api.stage.openshift.com"
if [[ "${OCM_LOGIN_ENV}" == "production" ]] ; then
  ocm_api_url="https://api.openshift.com"
elif [[ "${OCM_LOGIN_ENV}" == "integration" ]] ; then
  ocm_api_url="https://api.integration.openshift.com"
fi

ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

oc create secret -n default generic rosa-creds-secret --from-literal=ocmToken="${ROSA_TOKEN}" --from-literal=ocmApiUrl="${ocm_api_url}"

cat <<EOF | oc apply -f -
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSClusterControllerIdentity
metadata:
  name: "default"
spec:
  allowedNamespaces: {}
EOF

# prepare env variables
export OPENSHIFT_VERSION=${OPENSHIFT_VERSION}
export CLUSTER_NAME=${CLUSTER_NAME}
export AWS_REGION=${REGION}

if [[ ! -z "$AVAILABILITY_ZONES" ]]; then
  AVAILABILITY_ZONES=$(echo $AVAILABILITY_ZONES | sed -E "s|(\w+)|${REGION}&|g")
fi
export AWS_AVAILABILITY_ZONE=${AVAILABILITY_ZONES}

AWS_ACCOUNT_ID=$(aws sts get-caller-identity  | jq '.Account' | cut -d'"' -f2 | tr -d '\n')
export AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}

OIDC_CONFIG_ID=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')
export OIDC_CONFIG_ID=${OIDC_CONFIG_ID}

ACCOUNT_ROLES_PREFIX_FILE="${SHARED_DIR}/account-roles-prefix"
ACCOUNT_ROLES_PREFIX=$(cat "${ACCOUNT_ROLES_PREFIX_FILE}")
export ACCOUNT_ROLES_PREFIX=${ACCOUNT_ROLES_PREFIX}

OPERATOR_ROLES_PREFIX_FILE="${SHARED_DIR}/operator-roles-prefix"
OPERATOR_ROLES_PREFIX=$(cat "${OPERATOR_ROLES_PREFIX_FILE}")
export OPERATOR_ROLES_PREFIX=${OPERATOR_ROLES_PREFIX}

PUBLIC_SUBNET_ID=$(cat ${SHARED_DIR}/public_subnet_ids | tr -d "[']")
export PUBLIC_SUBNET_ID=${PUBLIC_SUBNET_ID}
PRIVATE_SUBNET_ID=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']")
export PRIVATE_SUBNET_ID=${PRIVATE_SUBNET_ID}

template_file_name="cluster-template-rosa-machinepool.yaml"
template_file="/tmp/${template_file_name}"
render_file="/tmp/cluster-rosa-machinepool.yaml"
curl -LJ https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-aws/main/templates/${template_file_name} -o ${template_file}
cat ${template_file} | /tmp/bin/envsubst > ${render_file}

# replace the operator roles with the real ones.
OPERATOR_ROLES_ARNS_FILE="${SHARED_DIR}/operator-roles-arns"
imageRegistryARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "image-registry")
storageARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "csi-drivers")
networkARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "network-config")

sed -i 's#^    storageARN: .*#    storageARN: "'"$storageARN"'"#' ${render_file}
sed -i 's#^    imageRegistryARN: .*#    imageRegistryARN: "'"$imageRegistryARN"'"#' ${render_file}
sed -i 's#^    networkARN: .*#    networkARN: "'"$networkARN"'"#' ${render_file}

cat ${render_file} > "${SHARED_DIR}/rosa-capi-cluster.yaml"
cat "${SHARED_DIR}/rosa-capi-cluster.yaml"
oc apply -f "${SHARED_DIR}/rosa-capi-cluster.yaml" -n default
oc patch rosacontrolplane -n default ${CLUSTER_NAME}-control-plane -p '{"spec":{"credentialsSecretRef":{"name":"rosa-creds-secret"}}}' --type=merge

# wait for cluster ready
retry is_hcp_started || exit 1
CLUSTER_ID=$(rosa describe cluster -c ${CLUSTER_NAME} -o json | jq '.id' | cut -d'"' -f2 | tr -d '\n')
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n $CLUSTER_ID > $SHARED_DIR/cluster-id
echo "rosa" > $SHARED_DIR/cluster-type

# collect rosa hcp info
rosa logs install -c ${CLUSTER_ID} --watch
echo "Waiting for cluster ready..."
CLUSTER_INSTALL_LOG="${ARTIFACT_DIR}/.install.log"
start_time=$(date +"%s")
while true; do
  sleep 60
  CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.state')
  echo "Cluster state: ${CLUSTER_STATE}"
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    echo "Cluster is reported as ready"
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster to be ready"
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" && "${CLUSTER_STATE}" != "waiting" && "${CLUSTER_STATE}" != "validating" ]]; then
    rosa logs install -c ${CLUSTER_ID} > "${CLUSTER_INSTALL_LOG}" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 0
  fi
done
rosa logs install -c ${CLUSTER_ID} > "${CLUSTER_INSTALL_LOG}"

CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.state')
if [[ "${CLUSTER_STATE}" != "ready" ]]; then
    echo "error: Cluster ${CLUSTER_NAME} ${CLUSTER_ID} is not in the ready status, ${CLUSTER_STATE}"
    exit 1
fi

API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
CONSOLE_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.console.url')
if [[ "${API_URL}" == "null" ]]; then
  # for hosted-cp only
  port="443"
  echo "warning: API URL was null, attempting to build API URL"
  base_domain=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.dns.base_domain')
  CLUSTER_NAME=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.name')
  echo "info: Using baseDomain : ${base_domain} and clusterName : ${CLUSTER_NAME}"
  API_URL="https://api.${CLUSTER_NAME}.${base_domain}:${port}"
  CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_NAME}.${base_domain}"
fi

echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
echo "${API_URL}" > "${SHARED_DIR}/api.url"

PRODUCT_ID=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.infra_id')
if [[ "${INFRA_ID}" == "null" ]]; then
  # Currently, there is no infra_id for rosa hypershift cluster, use a fake one instead of null
  INFRA_ID=$CLUSTER_NAME
fi
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"

# backup mgmt cluster kubeconfig
mv $KUBECONFIG "${SHARED_DIR}/mgmt_kubeconfig"

