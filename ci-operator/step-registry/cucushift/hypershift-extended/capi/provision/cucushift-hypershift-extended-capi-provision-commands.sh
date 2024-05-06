#!/bin/bash

set -euo pipefail

function retry() {
    local check_func=$1
    shift
    local max_retries=40
    local retry_delay=60
    local retries=0

    while (( retries < max_retries )); do
        if $check_func "$@" ; then
            echo "check function finished successfully, return 0"
            return 0
        fi

        retries=$(( retries + 1 ))
        if (( retries < max_retries )); then
            echo "Retrying in $retry_delay seconds..."
            sleep $retry_delay
        fi
    done

    echo "Failed to run check function $1 after $max_retries attempts."
    return 1
}

function is_hcp_started() {
    local cluster_res
    cluster_res=$(rosa list clusters | grep ${CLUSTER_NAME})
    if [[ -n "${cluster_res}" ]] ; then
      return 0
    fi
    return 1
}

function is_machine_pool_ready() {
  local nodepool=$1
  rosa list machinepool -c "${CLUSTER_NAME}" | grep "${nodepool}" >/dev/null || return 1
  rosa describe machinepool -c "${CLUSTER_NAME}" --machinepool "${nodepool}" -ojson | jq -e '.replicas == .status.current_replicas' >/dev/null && return 0 || return 1
}

function download_envsubst() {
    mkdir -p /tmp/bin
    export PATH=/tmp/bin:$PATH
    curl -L https://github.com/a8m/envsubst/releases/download/v1.4.2/envsubst-Linux-x86_64 -o /tmp/bin/envsubst && chmod +x /tmp/bin/envsubst
}

function rosa_login() {
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
      ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
    else
      echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
      exit 1
    fi

    #create secret based on rosa token
    oc create secret -n default generic rosa-creds-secret --from-literal=ocmToken="${ROSA_TOKEN}" --from-literal=ocmApiUrl="${ocm_api_url}"
}

function export_envs() {
    # kubeconfig
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
      export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
    fi

    # aws env
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    export AWS_REGION=${REGION}
    export AWS_PAGER=""

    # export capi env variables
    prefix="ci-capi-hcp-test-long-name"
    subfix=$(openssl rand -hex 10)
    CLUSTER_NAME=${CLUSTER_NAME:-"$prefix-$subfix"}
    echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
    export CLUSTER_NAME=${CLUSTER_NAME}
    export OPENSHIFT_VERSION=${OPENSHIFT_VERSION}

    AWS_ACCOUNT_ID=$(aws sts get-caller-identity  | jq '.Account' | cut -d'"' -f2 | tr -d '\n')
    export AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}

    OIDC_CONFIG_ID=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')
    export OIDC_CONFIG_ID=${OIDC_CONFIG_ID}

    ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")
    export ACCOUNT_ROLES_PREFIX=${ACCOUNT_ROLES_PREFIX}

    OPERATOR_ROLES_PREFIX=$(cat "${SHARED_DIR}/operator-roles-prefix")
    export OPERATOR_ROLES_PREFIX=${OPERATOR_ROLES_PREFIX}

    OPERATOR_ROLES_ARNS_FILE="${SHARED_DIR}/operator-roles-arns"
    IMAGE_REGISTRY_ARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "image-registry")
    STORAGE_ARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "csi-drivers")
    NETWORK_ARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "network-config")
    INGRESS_ARN=$(cat "${OPERATOR_ROLES_ARNS_FILE}" | grep "ingress-operator")
    export IMAGE_REGISTRY_ARN=${IMAGE_REGISTRY_ARN}
    export STORAGE_ARN=${STORAGE_ARN}
    export NETWORK_ARN=${NETWORK_ARN}
    export INGRESS_ARN=${INGRESS_ARN}

    ADDITIONAL_TAGS_YAML=""
    TAGS="capi-prow-ci: ${CLUSTER_NAME}"
    if [[ -n "${ADDITIONAL_TAGS}" ]]; then
      TagsKeyValue=$(echo ${ADDITIONAL_TAGS} | sed 's/\([^ ,]\+\):\([^ ,]\+\)/\1: \2/g')
      TAGS="${TAGS},${TagsKeyValue}"
    fi
    IFS=',' read -ra tag_arr <<< "${TAGS}"
    for tag in "${tag_arr[@]}"; do ADDITIONAL_TAGS_YAML+="    ${tag}"$'\n'; done
    export ADDITIONAL_TAGS_YAML=${ADDITIONAL_TAGS_YAML}

    AVAILABILITY_ZONE_YAML=""
    if [[ -n "${AVAILABILITY_ZONES}" ]]; then
      AVAILABILITY_ZONES=$(echo $AVAILABILITY_ZONES | sed -E "s|(\w+)|${REGION}&|g")
    else
      AVAILABILITY_ZONES=$(cat ${SHARED_DIR}/availability_zones | tr -d "[']")
    fi
    IFS=',' read -ra zone_arr <<< "${AVAILABILITY_ZONES}"
    for zone in "${zone_arr[@]}"; do AVAILABILITY_ZONE_YAML+="  - ${zone}"$'\n'; done
    export AVAILABILITY_ZONE_YAML=${AVAILABILITY_ZONE_YAML}

    PUBLIC_SUBNET_IDs=$(cat ${SHARED_DIR}/public_subnet_ids | tr -d "[']")
    PRIVATE_SUBNET_IDs=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']")

    SUBNET_LIST_YAML=""
    IFS=',' read -ra private_subnet_arr <<< "${PRIVATE_SUBNET_IDs}"
    for subnet in "${private_subnet_arr[@]}"; do SUBNET_LIST_YAML+="  - ${subnet}"$'\n'; done

    # do not set public subnet for private cluster
    if [[ "${ENDPOINT_ACCESS}" == "Public" ]]; then
      IFS=',' read -ra public_subnet_arr <<< "${PUBLIC_SUBNET_IDs}"
      for subnet in "${public_subnet_arr[@]}"; do SUBNET_LIST_YAML+="  - ${subnet}"$'\n'; done
    fi
    export SUBNET_LIST_YAML=${SUBNET_LIST_YAML}

    MACHINEPOOL_PRIVATE_SUBNET_ID=${private_subnet_arr[0]}
    export MACHINEPOOL_PRIVATE_SUBNET_ID=${MACHINEPOOL_PRIVATE_SUBNET_ID}

    if [[ "$ADDITIONAL_SECURITY_GROUP" == "true" ]]; then
      ADDITIONAL_SECURITY_GROUPS_YAML=""
      SECURITY_GROUP_IDs=$(cat ${SHARED_DIR}/security_groups_ids | xargs |sed 's/ /,/g')
      IFS=',' read -ra sg_arr <<< "${SECURITY_GROUP_IDs}"
      for sg in "${sg_arr[@]}"; do ADDITIONAL_SECURITY_GROUPS_YAML+="  - ${sg}"$'\n'; done
      export ADDITIONAL_SECURITY_GROUPS_YAML="  additionalSecurityGroups:
${ADDITIONAL_SECURITY_GROUPS_YAML}"
    fi

    # default machinepool autoscaling spec in rosacontrolplane
    if [[ -n "${DEFAULT_MP_MIN_REPLICAS}" ]] && [[ -n "${DEFAULT_MP_MAX_REPLICAS}" ]] ; then
      DEFAULT_MP_AUTOSCALING_YAML="  defaultMachinePoolSpec:
    autoscaling:
      minReplicas: ${DEFAULT_MP_MIN_REPLICAS}
      maxReplicas: ${DEFAULT_MP_MAX_REPLICAS}"
      export DEFAULT_MP_AUTOSCALING_YAML=${DEFAULT_MP_AUTOSCALING_YAML}
    fi

    # machinepool autosacling spec in rosamachinepool
    if [[ -n "${MIN_REPLICAS}" ]] && [[ -n "${MAX_REPLICAS}" ]] ; then
      MP_AUTOSCALING_YAML="  autoscaling:
    minReplicas: ${MIN_REPLICAS}
    maxReplicas: ${MAX_REPLICAS}"
      export MP_AUTOSCALING_YAML=${MP_AUTOSCALING_YAML}
    fi

    if [[ -n "${CLUSTER_SECTOR}" ]]; then
      psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${CLOUD_PROVIDER_REGION}' and status in ('ready')" | jq -r '.items[].provision_shard_reference.id')
      if [[ -z "$psList" ]]; then
        echo "no ready provision shard found, trying to find maintenance status provision shard"
        # try to find maintenance mode SC, currently osdfm api doesn't support status in ('ready', 'maintenance') query.
        psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${CLOUD_PROVIDER_REGION}' and status in ('maintenance')" | jq -r '.items[].provision_shard_reference.id')
        if [[ -z "$psList" ]]; then
          echo "No available provision shard!"
          exit 1
        fi
      fi
      PROVISION_SHARD_ID=$(echo "$psList" | head -n 1)
      export PROVISION_SHARD_ID="  provisionShardID: ${PROVISION_SHARD_ID}"
    fi

    if [[ "$ETCD_ENCRYPTION" == "true" ]]; then
      kms_key_arn=$(cat ${SHARED_DIR}/aws_kms_key_arn)
      export ETCD_ENCRYPTION_KMS_ARN="  etcdEncryptionKMSARN: ${kms_key_arn}"
    fi

    if [[ "$ENABLE_AUDIT_LOG" == "true" ]]; then
      iam_role_arn=$(head -n 1 ${SHARED_DIR}/iam_role_arn)
      export AUDIT_LOG_ROLE_ARN="  auditLogRoleARN: ${iam_role_arn}"
    fi

    if [[ -n "$DOMAIN_PREFIX" ]]; then
       export DOMAIN_PREFIX="  domainPrefix: ${DOMAIN_PREFIX}"
    fi

    export NODEPOOL_NAME="nodepool-0"

#    # some other optional spec of rosacontrolplane
#    export MACHINE_CIDR=${MACHINE_CIDR}
#    export NETWORK_TYPE=${NETWORK_TYPE}
#    export ENDPOINT_ACCESS=${ENDPOINT_ACCESS}
}

# main
export_envs
rosa_login
download_envsubst

# create AWSClusterControllerIdentity
cat <<EOF | oc -n default apply -f -
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSClusterControllerIdentity
metadata:
  name: "default"
spec:
  allowedNamespaces: {}
EOF

# create Cluster, ROSACluster and ROSAControlPlane
# it is based on https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-aws/main/templates/cluster-template-rosa-machinepool.yaml
envsubst <<"EOF" | oc -n default apply -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: "${CLUSTER_NAME}"
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: ROSACluster
    name: "${CLUSTER_NAME}"
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: ROSAControlPlane
    name: "${CLUSTER_NAME}-control-plane"
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ROSACluster
metadata:
  name: "${CLUSTER_NAME}"
spec: {}
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: ROSAControlPlane
metadata:
  name: "${CLUSTER_NAME}-control-plane"
spec:
  rosaClusterName: ${CLUSTER_NAME:0:54}
  version: "${OPENSHIFT_VERSION}"
  region: "${AWS_REGION}"
  endpointAccess: "${ENDPOINT_ACCESS}"
${ETCD_ENCRYPTION_KMS_ARN}
${AUDIT_LOG_ROLE_ARN}
${DOMAIN_PREFIX}
${PROVISION_SHARD_ID}
  network:
    machineCIDR: "${MACHINE_CIDR}"
    networkType: "${NETWORK_TYPE}"
${DEFAULT_MP_AUTOSCALING_YAML}
  additionalTags:
${ADDITIONAL_TAGS_YAML}
  rolesRef:
    ingressARN: "${INGRESS_ARN}"
    imageRegistryARN: "${IMAGE_REGISTRY_ARN}"
    storageARN: "${STORAGE_ARN}"
    networkARN: "${NETWORK_ARN}"
    kubeCloudControllerARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OPERATOR_ROLES_PREFIX}-kube-system-kube-controller-manager"
    nodePoolManagementARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OPERATOR_ROLES_PREFIX}-kube-system-capa-controller-manager"
    controlPlaneOperatorARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OPERATOR_ROLES_PREFIX}-kube-system-control-plane-operator"
    kmsProviderARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OPERATOR_ROLES_PREFIX}-kube-system-kms-provider"
  oidcID: "${OIDC_CONFIG_ID}"
  subnets:
${SUBNET_LIST_YAML}
  availabilityZones:
${AVAILABILITY_ZONE_YAML}
  installerRoleARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role"
  supportRoleARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Support-Role"
  workerRoleARN: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Worker-Role"
EOF

oc -n default patch rosacontrolplane ${CLUSTER_NAME}-control-plane -p '{"spec":{"credentialsSecretRef":{"name":"rosa-creds-secret"}}}' --type=merge

# create rosamachinepool
envsubst <<"EOF" | oc -n default apply -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: "${CLUSTER_NAME}-pool-0"
spec:
  clusterName: "${CLUSTER_NAME}"
  replicas: 1
  template:
    spec:
      clusterName: "${CLUSTER_NAME}"
      bootstrap:
        dataSecretName: ""
      infrastructureRef:
        name: "${CLUSTER_NAME}-pool-0"
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
        kind: ROSAMachinePool
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ROSAMachinePool
metadata:
  name: "${CLUSTER_NAME}-pool-0"
spec:
  nodePoolName: "${NODEPOOL_NAME}"
  instanceType: "m5.xlarge"
  subnet: "${MACHINEPOOL_PRIVATE_SUBNET_ID}"
  version: "${OPENSHIFT_VERSION}"
${MP_AUTOSCALING_YAML}
${ADDITIONAL_SECURITY_GROUPS_YAML}
  additionalTags:
${ADDITIONAL_TAGS_YAML}
  nodeDrainGracePeriod: ${NODE_DRAIN_GRACE_PERIOD}
EOF

oc -n default get rosamachinepool ${CLUSTER_NAME}-pool-0 -oyaml > "/tmp/${CLUSTER_NAME}-pool-0.yaml"
oc -n default get rosacontrolplane ${CLUSTER_NAME}-control-plane -oyaml > "/tmp/${CLUSTER_NAME}-control-plane.yaml"
mv "/tmp/${CLUSTER_NAME}-pool-0.yaml" ${ARTIFACT_DIR}/
mv "/tmp/${CLUSTER_NAME}-control-plane.yaml" ${ARTIFACT_DIR}/

# wait for cluster control plane ready
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

# do not check worker node here
# wait for cluster machinepool ready
# retry is_machine_pool_ready "${NODEPOOL_NAME}"
# echo "machine pool ${CLUSTER_NAME}-pool-0 is ready now"