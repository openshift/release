#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}"

MI_ARGS=""
if [[ "${AKS_USE_HYPERSHIFT_MI}" == "true" ]]; then
    HYPERSHIFT_MI_LOCATION="/etc/hypershift-ci-jobs-azurecreds/aks-mi-info.json"
    ASSIGN_IDENTITY="$(<"${HYPERSHIFT_MI_LOCATION}" jq -r .assignIdentity)"
    KUBELET_ASSIGN_IDENTITY="$(<"${HYPERSHIFT_MI_LOCATION}" jq -r .kubeletAssignIdentity)"

    MI_ARGS="--assign-identity ${ASSIGN_IDENTITY} --assign-kubelet-identity ${KUBELET_ASSIGN_IDENTITY}"
fi

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "Upgrading azure-cli for NAP support"
    pip-3 install --user 'azure-cli>=2.75.0'
    export PATH="${HOME}/.local/bin:${PATH}"
fi

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

CLUSTER_AUTOSCALER_ARGS=""
if [[ "${ENABLE_CLUSTER_AUTOSCALER:-}" == "true" ]] && [[ "${ENABLE_NAP:-}" != "true" ]]; then
    CLUSTER_AUTOSCALER_ARGS=" --cluster-autoscaler-profile balance-similar-node-groups=true"
fi

CERT_ROTATION_ARGS=""
if [[ "${ENABLE_AKS_CERT_ROTATION:-}" == "true" ]]; then
    CERT_ROTATION_ARGS+=" --enable-secret-rotation"

    if [[ "${AKS_CERT_ROTATION_POLL_INTERVAL:-}" != "" ]]; then
        CERT_ROTATION_ARGS+=" --rotation-poll-interval ${AKS_CERT_ROTATION_POLL_INTERVAL}"
    fi
fi

echo "Creating resource group for the aks cluster"
RESOURCEGROUP="${RESOURCE_NAME_PREFIX}-aks-rg"
az group create --name "$RESOURCEGROUP" --location "$AZURE_LOCATION"
echo "$RESOURCEGROUP" > "${SHARED_DIR}/resourcegroup_aks"

echo "Building up the aks create command"
CLUSTER="${RESOURCE_NAME_PREFIX}-aks-cluster"
AKS_CREATE_COMMAND=(
    az aks create
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
    --load-balancer-sku "$AKS_LB_SKU"
    --os-sku "$AKS_OS_SKU"
    "${CLUSTER_AUTOSCALER_ARGS:-}"
    "${CERT_ROTATION_ARGS:-}"
    "${MI_ARGS:-}"
    --location "$AZURE_LOCATION"
    --network-plugin azure
    --network-policy azure
    --max-pods 250
)

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "NAP is enabled, adding --node-provisioning-mode Auto"
    AKS_CREATE_COMMAND+=(--node-provisioning-mode Auto)
fi

if [[ -n "$AKS_ADDONS" ]]; then
     AKS_CREATE_COMMAND+=(--enable-addons "$AKS_ADDONS")
fi

# Version prioritization: specific > latest > default
if [[ -n "$AKS_K8S_VERSION" ]]; then
    AKS_CREATE_COMMAND+=(--kubernetes-version "$AKS_K8S_VERSION")
elif [[ "$USE_LATEST_K8S_VERSION" == "true" ]]; then
    K8S_LATEST_VERSION=$(az aks get-versions --location "${AZURE_LOCATION}" --output json --query 'max(orchestrators[?isPreview==`null`].orchestratorVersion)')
    AKS_CREATE_COMMAND+=(--kubernetes-version "$K8S_LATEST_VERSION")
fi

if [[ "$AKS_GENERATE_SSH_KEYS" == "true" ]]; then
    AKS_CREATE_COMMAND+=(--generate-ssh-keys)
fi

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKS_CREATE_COMMAND+=(--enable-fips-image)
fi

echo "Creating AKS cluster"
eval "${AKS_CREATE_COMMAND[*]}"

echo "Waiting for AKS cluster to be ready"
az aks wait --created --name "$CLUSTER" --resource-group "$RESOURCEGROUP" --interval 30

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "NAP is enabled, skipping manual zone-specific node pool creation"
elif [[ -n "$AKS_ZONES" ]]; then
    echo "Creating zone-specific node pools"
    read -ra ZONE_ARRAY <<< "$AKS_ZONES"

    for zone in "${ZONE_ARRAY[@]}"; do
        echo "Creating node pool for zone $zone"
        NODEPOOL_NAME="npz${zone}"

        NODEPOOL_CMD=(
            az aks nodepool add
            --resource-group "$RESOURCEGROUP"
            --cluster-name "$CLUSTER"
            --name "$NODEPOOL_NAME"
            --zones "$zone"
            --max-pods 250
            --node-count "$((AKS_NODE_COUNT / ${#ZONE_ARRAY[@]}))"
        )

        if [[ -n "$AKS_NODE_VM_SIZE" ]]; then
            NODEPOOL_CMD+=(--node-vm-size "$AKS_NODE_VM_SIZE")
        fi

        if [[ "${ENABLE_CLUSTER_AUTOSCALER:-}" == "true" ]]; then
            NODEPOOL_CMD+=(--enable-cluster-autoscaler)

            if [[ "${AKS_CLUSTER_AUTOSCALER_MIN_NODES:-}" != "" ]]; then
                NODEPOOL_CMD+=(--min-count "$((AKS_CLUSTER_AUTOSCALER_MIN_NODES))")
            fi

            if [[ "${AKS_CLUSTER_AUTOSCALER_MAX_NODES:-}" != "" ]]; then
                NODEPOOL_CMD+=(--max-count "$((AKS_CLUSTER_AUTOSCALER_MAX_NODES))")
            fi
        fi

        echo "Executing node pool creation command for zone $zone"
        eval "${NODEPOOL_CMD[*]}"
    done
fi

echo "Saving cluster info"
echo "$CLUSTER" > "${SHARED_DIR}/cluster-name"
if [[ $AKS_ADDONS == *azure-keyvault-secrets-provider* ]]; then
    az aks show -n "$CLUSTER" -g "$RESOURCEGROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -r > "${SHARED_DIR}/aks_keyvault_secrets_provider_client_id"
    # Grant MI required permissions to the KV which will be created in the same RG as the AKS cluster
    AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(az aks show -n "$CLUSTER" -g "$RESOURCEGROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -r)"
    echo "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" > "${SHARED_DIR}/kv-object-id"
fi

echo "Building up the aks get-credentials command"
AKS_GET_CREDS_COMMAND=(
    az aks get-credentials
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
)

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKS_GET_CREDS_COMMAND+=(--overwrite-existing)
fi

echo "Getting kubeconfig to the AKS cluster"
# shellcheck disable=SC2034
KUBECONFIG="${SHARED_DIR}/kubeconfig"
eval "${AKS_GET_CREDS_COMMAND[*]}"

if [[ "${ENABLE_NAP:-}" == "true" ]]; then
    echo "Configuring NAP Karpenter resources"

    # Build zone requirements from AKS_ZONES
    ZONE_VALUES=""
    if [[ -n "${AKS_ZONES:-}" ]]; then
        read -ra ZONE_ARRAY <<< "$AKS_ZONES"
        for zone in "${ZONE_ARRAY[@]}"; do
            ZONE_VALUES+="            - ${AZURE_LOCATION}-${zone}
"
        done
    fi

    NODEPOOL_YAML=$(cat <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      expireAfter: Never
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64
        - key: kubernetes.io/os
          operator: In
          values:
            - linux
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - "${NAP_SKU_FAMILY:-D}"
        - key: karpenter.azure.com/sku-cpu
          operator: In
          values:
            - "${NAP_SKU_CPU:-16}"
        - key: karpenter.azure.com/sku-version
          operator: In
          values:
            - "2"
            - "3"
            - "4"
            - "5"
$(if [[ -n "$ZONE_VALUES" ]]; then
cat <<ZONES
        - key: topology.kubernetes.io/zone
          operator: In
          values:
${ZONE_VALUES}
ZONES
fi)
  limits:
    cpu: "200"
  disruption:
    budgets:
      - nodes: "0"
EOF
)

    # Map AKS_OS_SKU to Karpenter imageFamily
    NAP_IMAGE_FAMILY="AzureLinux"
    if [[ "${AKS_OS_SKU}" == "Ubuntu" ]]; then
        NAP_IMAGE_FAMILY="Ubuntu"
    fi

    NODECLASS_YAML=$(cat <<EOF
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: default
spec:
  imageFamily: "${NAP_IMAGE_FAMILY}"
EOF
)

    echo "Applying Karpenter NodePool"
    echo "$NODEPOOL_YAML" | oc apply -f -

    echo "Applying Karpenter AKSNodeClass"
    echo "$NODECLASS_YAML" | oc apply -f -

    # Create placeholder pods to trigger NAP node provisioning.
    # Resource requests are set high enough to ensure one pod per D16-equivalent node.
    PLACEHOLDER_YAML=$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nap-placeholder
  namespace: default
spec:
  replicas: ${AKS_NODE_COUNT:-9}
  selector:
    matchLabels:
      app: nap-placeholder
  template:
    metadata:
      labels:
        app: nap-placeholder
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: nap-placeholder
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "14"
              memory: "56Gi"
EOF
)

    echo "Creating placeholder deployment to trigger NAP node provisioning"
    echo "$PLACEHOLDER_YAML" | oc apply -f -

    collect_nap_artifacts() {
        echo "Collecting NAP artifacts"
        oc get nodepool.karpenter.sh -o yaml > "${ARTIFACT_DIR}/karpenter-nodepools.yaml" 2>&1 || true
        oc get aksnodeclass -o yaml > "${ARTIFACT_DIR}/karpenter-aksnodeclasses.yaml" 2>&1 || true
        oc get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,READY:.status.conditions[-1:].status' > "${ARTIFACT_DIR}/nap-node-zone-distribution.txt" 2>&1 || true
    }

    echo "Waiting for NAP to provision nodes"
    # Wait for the desired number of Ready nodes (NAP-provisioned + system pool)
    DESIRED_NODES=$((${AKS_NODE_COUNT:-9} + 3))
    NAP_TIMEOUT=600
    NAP_ELAPSED=0
    while true; do
        READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
        if [[ "$READY_NODES" -ge "$DESIRED_NODES" ]]; then
            echo "All $DESIRED_NODES nodes are ready"
            break
        fi
        if [[ "$NAP_ELAPSED" -ge "$NAP_TIMEOUT" ]]; then
            echo "ERROR: Timed out waiting for NAP nodes. Only $READY_NODES/$DESIRED_NODES ready."
            oc get nodes || true
            oc get nodepool.karpenter.sh -o yaml || true
            collect_nap_artifacts
            exit 1
        fi
        echo "Waiting for NAP nodes: $READY_NODES/$DESIRED_NODES ready (${NAP_ELAPSED}s/${NAP_TIMEOUT}s)..."
        sleep 30
        NAP_ELAPSED=$((NAP_ELAPSED + 30))
    done

    collect_nap_artifacts

    echo "Cleaning up placeholder deployment"
    oc delete deployment nap-placeholder -n default --ignore-not-found
fi

oc get nodes
oc version
