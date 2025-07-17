#!/bin/bash

set -euo pipefail; shopt -s inherit_errexit

export ARCH_TYPE
export BASE_DOMAIN
export WORKER_TYPE
export CP_TYPE
export WORKER_REPLICAS
export CP_REPLICAS
export ACM_MANAGED_CLUSTER_NAME
export SPOKE_CLUSTER_REGION=${MANAGED_CLUSTER_LEASED_RESOURCE}
export NETWORK_TYPE
export INSTALL_TIMEOUT_MINUTES
export SPOKE_CLUSTER_VERSION

export KUBECONFIG=${SHARED_DIR}/kubeconfig

#helpers
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found"; exit 1; }; }
json(){ oc -n "${1}" get "${2}" "${3}" -o json; }

need oc; need jq; need base64

# create namespace same as cluster name
oc create namespace $ACM_MANAGED_CLUSTER_NAME
oc project $ACM_MANAGED_CLUSTER_NAME

#create cluster-set
oc create -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: ${ACM_MANAGED_CLUSTER_NAME}-set
  namespace: $ACM_MANAGED_CLUSTER_NAME
spec: {}

EOF

# create namespace binding for the cluster-set
oc create -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${ACM_MANAGED_CLUSTER_NAME}-set
  namespace: $ACM_MANAGED_CLUSTER_NAME
spec:
  clusterSet: ${ACM_MANAGED_CLUSTER_NAME}-set
EOF


# extract aws credentials from cluster profile to store it as secret on test cluster so that it is discoverable by ACM
aws_cred="${CLUSTER_PROFILE_DIR}/.awscred"
aws_access_key_id=$(cat "${aws_cred}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
aws_secret_access_key=$(cat "${aws_cred}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)


# create secrets required for cluster creation on aws platform
oc -n $ACM_MANAGED_CLUSTER_NAME create secret generic acm-aws-secret  \
      --type=Opaque \
      --from-literal=aws_access_key_id="$aws_access_key_id" \
      --from-literal=aws_secret_access_key="$aws_secret_access_key" \
      --dry-run=client -o yaml | oc apply -f -

oc label secret acm-aws-secret \
  cluster.open-cluster-management.io/type=aws \
  cluster.open-cluster-management.io/credentials="" \
  -n $ACM_MANAGED_CLUSTER_NAME --overwrite \
  --dry-run=client -o yaml | oc apply -f -

# create pull-secret required by cluster deployment
oc -n $ACM_MANAGED_CLUSTER_NAME create secret generic pull-secret\
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
      --dry-run=client -o yaml | oc apply -f -

# create ssh-public-key secret required by cluster deployment
oc -n $ACM_MANAGED_CLUSTER_NAME create secret generic ssh-public-key\
    --type=Opaque \
    --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    --dry-run=client -o yaml | oc apply -f -

# create ssh-private-key secret required by cluster deployment
oc -n $ACM_MANAGED_CLUSTER_NAME create secret generic ssh-private-key\
    --type=Opaque \
    --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    --dry-run=client -o yaml | oc apply -f -



# create install-config
INSTALL_CONFIG_FILE=/tmp/install-config.yaml

cat > $INSTALL_CONFIG_FILE <<EOF
apiVersion: v1
metadata:
  name: $ACM_MANAGED_CLUSTER_NAME
baseDomain: $BASE_DOMAIN
controlPlane:
  architecture: $ARCH_TYPE
  hyperthreading: Enabled
  name: master
  replicas: $CP_REPLICAS
  platform:
    aws:
      type: $CP_TYPE
compute:
- hyperthreading: Enabled
  architecture: $ARCH_TYPE
  name: 'worker'
  replicas: $WORKER_REPLICAS
  platform:
    aws:
      type: $WORKER_TYPE
networking:
  networkType: $NETWORK_TYPE
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: $SPOKE_CLUSTER_REGION
sshKey: |-
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

# create install-config secret to be referenced in cluster deployment 
oc -n $ACM_MANAGED_CLUSTER_NAME create secret generic install-config \
   --type Opaque \
   --from-file install-config.yaml=/tmp/install-config.yaml \
   --dry-run=client -o yaml --save-config | oc apply -f -


cluster_imageset_name="$(
  oc get clusterimagesets.hive.openshift.io \
    -o jsonpath='{.items[*].metadata.name}' \
    | tr ' ' '\n' \
    | grep "^img${SPOKE_CLUSTER_VERSION}\." \
    | sort -V \
    | tail -n 1
)"

ocp_release_image="$(
  oc get clusterimageset "$cluster_imageset_name" \
    -o jsonpath='{.spec.releaseImage}'
)"


echo "cluster_image: ${OCP_RELEASE_IMAGE}"

# create clusterdeployment
CLUSTER_DEPLOYMENT_FILE=/tmp/clusterdeployment.yaml
cat > $CLUSTER_DEPLOYMENT_FILE <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
   name: $ACM_MANAGED_CLUSTER_NAME
   namespace: $ACM_MANAGED_CLUSTER_NAME
   labels:
    cloud: 'AWS'
    region: '${SPOKE_CLUSTER_REGION}'
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: '${ACM_MANAGED_CLUSTER_NAME}-set'
spec:
   baseDomain: $BASE_DOMAIN
   clusterName: $ACM_MANAGED_CLUSTER_NAME
   controlPlaneConfig:
    servingCertificates: {}
   platform:
      aws:
         region: $SPOKE_CLUSTER_REGION
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
  name: $ACM_MANAGED_CLUSTER_NAME
  labels:
    name: $ACM_MANAGED_CLUSTER_NAME
    cloud: Amazon
    region: $SPOKE_CLUSTER_REGION
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: ${ACM_MANAGED_CLUSTER_NAME}-set
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
  name: $ACM_MANAGED_CLUSTER_NAME
  namespace: $ACM_MANAGED_CLUSTER_NAME
spec:
  clusterName: $ACM_MANAGED_CLUSTER_NAME
  clusterNamespace: $ACM_MANAGED_CLUSTER_NAME
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


echo "[INFO]  Waiting for ClusterProvision to be completed..."
oc -n "${ACM_MANAGED_CLUSTER_NAME}" wait "ClusterDeployment/${ACM_MANAGED_CLUSTER_NAME}" --for jsonpath='{.status.powerState}=Running' --timeout "$((INSTALL_TIMEOUT_MINUTES * 60))s"

cd_json="$(oc -n "${ACM_MANAGED_CLUSTER_NAME}" get clusterdeployment "${ACM_MANAGED_CLUSTER_NAME}" -o json 2>/dev/null)"

installed="$(echo "$cd_json" | jq -r '
    any(.status.conditions[]?; .type=="Provisioned" and .status=="True")
    | tostring
  ')"

stop_reason="$(echo "$cd_json" | jq -r '
  try (
    .status.conditions[]?
    | select(.type=="ProvisionStopped" and .status=="True")
    | .reason
  ) // ""')"

if [[ "$installed" == "true" ]]; then
   echo "ClusterDeployment  status Installed==True"
elif [[ -n "$stop_reason" ]]; then
   echo "Provision stopped reason=$stop_reason"
   exit 2
else
   echo "Installation failed or timed out"
   exit 3
fi

oc -n "${ACM_MANAGED_CLUSTER_NAME}" get "Secret/$(
        oc -n "${ACM_MANAGED_CLUSTER_NAME}" get "ClusterDeployment/${ACM_MANAGED_CLUSTER_NAME}" \
            -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
    )" -o jsonpath='{.data.kubeconfig}' |
        base64 -d > "${SHARED_DIR}/managed-cluster-kubeconfig"