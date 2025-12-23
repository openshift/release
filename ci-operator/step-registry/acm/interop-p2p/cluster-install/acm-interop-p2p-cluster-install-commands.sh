#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

export ACM_SPOKE_ARCH_TYPE
export BASE_DOMAIN
export ACM_SPOKE_WORKER_TYPE
export ACM_SPOKE_CP_TYPE
export ACM_SPOKE_WORKER_REPLICAS
export ACM_SPOKE_CP_REPLICAS
export ACM_SPOKE_CLUSTER_NAME
export ACM_SPOKE_CLUSTER_REGION=${MANAGED_CLUSTER_LEASED_RESOURCE}
export ACM_SPOKE_NETWORK_TYPE
export ACM_SPOKE_INSTALL_TIMEOUT_MINUTES
export ACM_SPOKE_CLUSTER_VERSION

#helpers
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found"; exit 1; }; }
json_get() { oc -n "${1}" get "${2}" "${3}" -o json; }

need oc; need jq; need base64

# create namespace same as cluster name
oc create namespace $ACM_SPOKE_CLUSTER_NAME
oc project $ACM_SPOKE_CLUSTER_NAME

#create cluster-set
oc create -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}-set
  namespace: $ACM_SPOKE_CLUSTER_NAME
spec: {}

EOF

# create namespace binding for the cluster-set
oc create -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}-set
  namespace: $ACM_SPOKE_CLUSTER_NAME
spec:
  clusterSet: ${ACM_SPOKE_CLUSTER_NAME}-set
EOF

# extract aws credentials from cluster profile to store it as secret on test cluster so that it is discoverable by ACM

oc -n $ACM_SPOKE_CLUSTER_NAME create secret generic acm-aws-secret  \
      --type=Opaque \
      --from-file=aws_access_key_id=<( set +x
        printf '%s' "$(
            cat "${CLUSTER_PROFILE_DIR}/.awscred" |
            sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q'
        )"
      true ) \
      --from-file=aws_secret_access_key=<( set +x
        printf '%s' "$(
            cat "${CLUSTER_PROFILE_DIR}/.awscred" |
            sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q'
        )"
      true ) \
      --dry-run=client -o yaml | oc apply -f -

oc label secret acm-aws-secret \
  cluster.open-cluster-management.io/type=aws \
  cluster.open-cluster-management.io/credentials="" \
  -n $ACM_SPOKE_CLUSTER_NAME --overwrite \
  --dry-run=client -o yaml | oc apply -f -

# create pull-secret required by cluster deployment
oc -n $ACM_SPOKE_CLUSTER_NAME create secret generic pull-secret\
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
      --dry-run=client -o yaml | oc apply -f -

# create ssh-public-key secret required by cluster deployment
oc -n $ACM_SPOKE_CLUSTER_NAME create secret generic ssh-public-key\
    --type=Opaque \
    --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    --dry-run=client -o yaml | oc apply -f -

# create ssh-private-key secret required by cluster deployment
oc -n $ACM_SPOKE_CLUSTER_NAME create secret generic ssh-private-key\
    --type=Opaque \
    --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    --dry-run=client -o yaml | oc apply -f -

# create install-config
INSTALL_CONFIG_FILE=/tmp/install-config.yaml

cat > $INSTALL_CONFIG_FILE <<EOF
apiVersion: v1
metadata:
  name: $ACM_SPOKE_CLUSTER_NAME
baseDomain: $BASE_DOMAIN
controlPlane:
  architecture: $ACM_SPOKE_ARCH_TYPE
  hyperthreading: Enabled
  name: master
  replicas: $ACM_SPOKE_CP_REPLICAS
  platform:
    aws:
      type: $ACM_SPOKE_CP_TYPE
compute:
- hyperthreading: Enabled
  architecture: $ACM_SPOKE_ARCH_TYPE
  name: 'worker'
  replicas: $ACM_SPOKE_WORKER_REPLICAS
  platform:
    aws:
      type: $ACM_SPOKE_WORKER_TYPE
networking:
  networkType: $ACM_SPOKE_NETWORK_TYPE
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: $ACM_SPOKE_CLUSTER_REGION
sshKey: |-
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

# create install-config secret to be referenced in cluster deployment 
oc -n $ACM_SPOKE_CLUSTER_NAME create secret generic install-config \
   --type Opaque \
   --from-file install-config.yaml=/tmp/install-config.yaml \
   --dry-run=client -o yaml --save-config | oc apply -f -


cluster_imageset_name="$(
  oc get clusterimagesets.hive.openshift.io \
    -o jsonpath='{.items[*].metadata.name}' \
    | tr ' ' '\n' \
    | grep "^img${ACM_SPOKE_CLUSTER_VERSION}\." \
    | sort -V \
    | tail -n 1
)"

ocp_release_image="$(
  oc get clusterimageset "$cluster_imageset_name" \
    -o jsonpath='{.spec.releaseImage}'
)"


echo "cluster_image: ${ocp_release_image}"

# create clusterdeployment
CLUSTER_DEPLOYMENT_FILE=/tmp/clusterdeployment.yaml
cat > $CLUSTER_DEPLOYMENT_FILE <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
   name: $ACM_SPOKE_CLUSTER_NAME
   namespace: $ACM_SPOKE_CLUSTER_NAME
   labels:
    cloud: 'AWS'
    region: '${ACM_SPOKE_CLUSTER_REGION}'
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: '${ACM_SPOKE_CLUSTER_NAME}-set'
spec:
   baseDomain: $BASE_DOMAIN
   clusterName: $ACM_SPOKE_CLUSTER_NAME
   controlPlaneConfig:
    servingCertificates: {}
   platform:
      aws:
         region: $ACM_SPOKE_CLUSTER_REGION
         credentialsSecretRef:
            name: acm-aws-secret
   pullSecretRef:
      name: pull-secret
   installAttemptsLimit: 1
   provisioning:
      installConfigSecretRef:
         name: install-config
      releaseImage: $ocp_release_image
      sshPrivateKeyRef:
         name: ssh-private-key
EOF

oc apply -f $CLUSTER_DEPLOYMENT_FILE

# create managed cluster reosurce
MANAGED_CLUSTER_FILE=/tmp/managed_cluster.yaml
cat > $MANAGED_CLUSTER_FILE <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: $ACM_SPOKE_CLUSTER_NAME
  labels:
    name: $ACM_SPOKE_CLUSTER_NAME
    cloud: Amazon
    region: $ACM_SPOKE_CLUSTER_REGION
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: ${ACM_SPOKE_CLUSTER_NAME}-set
spec:
  hubAcceptsClient: true
EOF

oc apply -f "$MANAGED_CLUSTER_FILE"

# create klusterlet addon config
KLUSTERLET_ADD_ON_CONFIG_FILE=/tmp/klusterletaddonconfig.yaml
cat > $KLUSTERLET_ADD_ON_CONFIG_FILE <<EOF
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: $ACM_SPOKE_CLUSTER_NAME
  namespace: $ACM_SPOKE_CLUSTER_NAME
spec:
  clusterName: $ACM_SPOKE_CLUSTER_NAME
  clusterNamespace: $ACM_SPOKE_CLUSTER_NAME
  clusterLabels:
    cloud: Amazon
    vendor: OpenShift
  applicationManager:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  certPolicyController:
    enabled: true
EOF

oc apply -f $KLUSTERLET_ADD_ON_CONFIG_FILE

echo "[INFO] Waiting for ClusterDeployment to reach status Provisioned=True (timeout=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m)"
# The correct, robust way to wait for Hive installation completion is the Provisioned condition.
oc -n "${ACM_SPOKE_CLUSTER_NAME}" wait "ClusterDeployment/${ACM_SPOKE_CLUSTER_NAME}" \
    --for condition=Provisioned \
    --timeout "${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m"

# Final Status Check (Retained from original, but simplified)
cd_json="$(json_get "${ACM_SPOKE_CLUSTER_NAME}" clusterdeployment "${ACM_SPOKE_CLUSTER_NAME}")"

installed="$(echo "$cd_json" | jq -r '
    .status.conditions[]?
    | select(.type=="Provisioned" and .status=="True")
    | .status
  ')"

if [[ "$installed" == "True" ]]; then
   echo "[SUCCESS] ClusterDeployment status Provisioned is True. Installation complete."
else
   stop_reason="$(echo "$cd_json" | jq -r '
     .status.conditions[]?
     | select(.type=="ProvisionStopped" and .status=="True")
     | .reason // "N/A"'
   )"
   echo "[FATAL] Installation failed or timed out. ProvisionStopped reason: ${stop_reason}"
   exit 3
fi

# --- 10. Extract Kubeconfig ---
echo "[INFO] Extracting admin kubeconfig."
oc -n "${ACM_SPOKE_CLUSTER_NAME}" get "Secret/$(
        oc -n "${ACM_SPOKE_CLUSTER_NAME}" get "ClusterDeployment/${ACM_SPOKE_CLUSTER_NAME}" \
            -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
    )" -o jsonpath='{.data.kubeconfig}' |
        base64 -d > "${SHARED_DIR}/managed-cluster-kubeconfig"

echo "[SUCCESS] Spoke cluster provisioning and ACM registration initiated successfully."

metadata_secret="$(
  oc -n "${ACM_SPOKE_CLUSTER_NAME}" get "ClusterDeployment/${ACM_SPOKE_CLUSTER_NAME}" \
            -o jsonpath='{.spec.clusterMetadata.metadataJSONSecretRef.name}'
)"
if [[ -z "$metadata_secret" ]]; then
  echo "[WARN] metadataJSONSecretRef is not set; metdata.json may not exist for this cluster"
else
  if oc -n "${ACM_SPOKE_CLUSTER_NAME}" get secret "${metadata_secret}" >/dev/null 2>&1; then
    oc -n "${ACM_SPOKE_CLUSTER_NAME}" get secret "${metadata_secret}" \
      -o jsonpath='{.data.metadata\.json}' | base64 -d \
      > "${SHARED_DIR}/managed.cluster.metadata.json"
  else
    echo "[Error] Secret '${metadata_secret}' not found in namespace '${ACM_SPOKE_CLUSTER_NAME}' "
  fi
fi
