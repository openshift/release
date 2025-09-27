#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



ARCH_TYPE=${ARCH_TYPE:-amd64}
BASE_DOMAIN=${BASE_DOMAIN:-cspilp.interop.ccitredhat.com}
WORKER_TYPE=${WORKER_TYPE:-m5.xlarge}
CP_TYPE=${CP_TYPE:-m5.xlarge}
WORKER_REPLICAS=${WORKER_REPLICAS:-3}
CP_REPLICAS=${CP_REPLICAS:-3}
CLUSTER_NAME=${CLUSTER_NAME:-spoke-cluster}
REGION=${SPOKE_CLUSTER_REGION}
NETWORK_TYPE=${NETWORK_TYPE:-OVNKubernetes}
INSTALL_TIMEOUT_MINUTES=${INSTALL_TIMEOUT_MINUTES:-100}
POLL_SECONDS=${POLL_SECONDS:-30}
LOG_SINCE=${LOG_SINCE:-30s}
OCP_RELEASE_IMAGE=${OCP_RELEASE_IMAGE:-}

cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

#helpers
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found"; exit 1; }; }
json(){ oc -n "$CLUSTER_NAME" get "$1" "$2" -o json; }
now(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }

need oc; need jq; need base64

oc create namespace $CLUSTER_NAME
oc project $CLUSTER_NAME

oc create -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: ${CLUSTER_NAME}-set
  namespace: ${CLUSTER_NAME}
spec: {}

EOF

oc create -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${CLUSTER_NAME}-set
  namespace: ${CLUSTER_NAME}
spec:
  clusterSet: ${CLUSTER_NAME}-set
EOF

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
# PULL_SECRET_JSON="$(jq -c . < ${CLUSTER_PROFILE_DIR}/config.json)"
AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)


oc -n "${CLUSTER_NAME}" create secret generic acm-aws-secret  \
      --type=Opaque \
      --from-literal=aws_access_key_id="$AWS_ACCESS_KEY_ID" \
      --from-literal=aws_secret_access_key="$AWS_SECRET_ACCESS_KEY" \
      --dry-run=client -o yaml | oc apply -f -

oc label secret acm-aws-secret \
  cluster.open-cluster-management.io/type=aws \
  cluster.open-cluster-management.io/credentials="" \
  -n "${CLUSTER_NAME}" --overwrite \
  --dry-run=client -o yaml | oc apply -f -

oc -n "${CLUSTER_NAME}" create secret generic pull-secret\
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
      --dry-run=client -o yaml | oc apply -f -

oc -n "${CLUSTER_NAME}" create secret generic ssh-public-key\
    --type=Opaque \
    --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    --dry-run=client -o yaml | oc apply -f -

oc -n "${CLUSTER_NAME}" create secret generic ssh-private-key\
    --type=Opaque \
    --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    --dry-run=client -o yaml | oc apply -f -


INSTALL_CONFIG_FILE=/tmp/install-config.yaml

cat > $INSTALL_CONFIG_FILE <<EOF
apiVersion: v1
metadata:
  name: ${CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
controlPlane:
  architecture: ${ARCH_TYPE}
  hyperthreading: Enabled
  name: master
  replicas: ${CP_REPLICAS}
  platform:
    aws:
      type: ${CP_TYPE}
compute:
- hyperthreading: Enabled
  architecture: ${ARCH_TYPE}
  name: 'worker'
  replicas: ${WORKER_REPLICAS}
  platform:
    aws:
      type: ${WORKER_TYPE}
networking:
  networkType: ${NETWORK_TYPE}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
sshKey: |-
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

oc -n ${CLUSTER_NAME} create secret generic install-config \
   --type Opaque \
   --from-file install-config.yaml=/tmp/install-config.yaml \
   --dry-run=client -o yaml --save-config | oc apply -f -

CLUSTER_DEPLOYMENT_FILE=/tmp/clusterdeployment.yaml
cat > $CLUSTER_DEPLOYMENT_FILE <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
   name: ${CLUSTER_NAME}
   namespace: ${CLUSTER_NAME}
   labels:
    cloud: 'AWS'
    region: '${REGION}'
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: '${CLUSTER_NAME}-set'
spec:
   baseDomain: ${BASE_DOMAIN}
   clusterName: ${CLUSTER_NAME}
   controlPlaneConfig:
    servingCertificates: {}
   platform:
      aws:
         region: ${REGION}
         credentialsSecretRef:
            name: acm-aws-secret
   pullSecretRef:
      name: pull-secret
   installAttemptsLimit: 1
   provisioning:
      installConfigSecretRef:
         name: install-config
      releaseImage: ${OCP_RELEASE_IMAGE}
      sshPrivateKeyRef:
         name: ssh-private-key
EOF

oc apply -f "$CLUSTER_DEPLOYMENT_FILE"

MANAGED_CLUSTER_FILE=/tmp/managed_cluster.yaml
cat > $MANAGED_CLUSTER_FILE <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: $CLUSTER_NAME
  labels:
    name: $CLUSTER_NAME
    cloud: Amazon
    region: $REGION
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: ${CLUSTER_NAME}-set
spec:
  hubAcceptsClient: true
EOF

oc apply -f "$MANAGED_CLUSTER_FILE"

KLUSTERLET_ADD_ON_CONFIG_FILE=/tmp/klusterletaddonconfig.yaml
cat > $KLUSTERLET_ADD_ON_CONFIG_FILE <<EOF
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: $CLUSTER_NAME
  namespace: $CLUSTER_NAME
spec:
  clusterName: $CLUSTER_NAME
  clusterNamespace: $CLUSTER_NAME
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

oc apply -f ${KLUSTERLET_ADD_ON_CONFIG_FILE}

#=====================
oc -n "$CLUSTER_NAME" patch clusterdeployment "$CLUSTER_NAME" --type=merge -p '{"spec":{"powerState":"Running"}}' >/dev/null || true

oc -n "$CLUSTER_NAME" annotate clusterdeployment "$CLUSTER_NAME" hive.openshift.io/try-install-now=true --overwrite >/dev/null || true

#=================================
deadline=$(( $(date +%s) + INSTALL_TIMEOUT_MINUTES*60 ))
# wait for cluster provision to show up
echo "[INFO] $(now) Waiting for ClusterProvision to be created..."
while true; do
  cnt=$(oc -n "$CLUSTER_NAME" get clusterprovisions -l hive.openshift.io/cluster-deployment-name="$CLUSTER_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
  if (( cnt > 0 )); then
     echo "[INFO] ClusterProvision detected."
     break
  fi
  if (( $(date +%s) > deadline )); then
     echo "[ERROR] Timeout waiting for ClusterProvision"
     exit 1
  fi
  sleep "$POLL_SECONDS"
done

#=====================
STREAM_PID=""
CURRENT_POD=""

cleanup() {
    [[ -n "${STREAM_PID:-}" ]] && kill "${STREAM_PID}" 2>/dev/null || true
}

trap cleanup EXIT

start_stream() {
    local pod="$1"
    [[ -z "$pod" ]] && return 0
    [[ "$pod" == "$CURRENT_POD" ]] && return 0
    [[  -n "${STREAM_PID:-}" ]] && { kill "${STREAM_PID}" 2>/dev/null || true; wait "${STREAM_PID}" 2>/dev/null || true; }
    CURRENT_POD="$pod"
    sleep 10
    echo
    echo "[INFO] $(now) Streaming installer logs from pod: $pod"
    ( oc -n "$CLUSTER_NAME" logs "$pod" -c installer -f --since="${LOG_SINCE}" || true ) & STREAM_PID=$!
}

pick_provision_pod() {
    oc -n "$CLUSTER_NAME" get pod -l hive.openshift.io/job-type=provision -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}


echo "[INFO] $(now) Waiting up to ${INSTALL_TIMEOUT_MINUTES}m for install to complete."

#============== wait logic with live logs
while true; do
  #start or switch log stream if a provision pod exists
  POD="$(pick_provision_pod || true)"
  [[ -n "$POD" ]] && start_stream "$POD"
  
  #success
  installed=$(oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -o jsonpath='{.spec.installed}' 2>/dev/null || echo "" )
  if [[ "$installed" == "true" ]]; then
    echo
    echo "[INFO] $(now) Install complete"
    break
  fi

  #terminal failure
  reason=$(oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -o json \
    | jq -r '.status.conditions[]? | select(.type=="ProvisionStopped" and .status=="True") | .reason' || true)
  if [[ -n "${reason:-}" ]]; then
    echo
    echo "[ERROR] Provision stopped (reason=${reason})."
    exit 2
  fi

  #timeout
  if (( $(date +%s) > deadline )); then
    echo
    echo "[ERROR] $(now) Install timed out after ${INSTALL_TIMEOUT_MINUTES} minutes"
    ecit 3
  fi

  sleep "$POLL_SECONDS"
done

# dump_diag() {
#   echo "====== DIAGNOSTICS ($(now)) ========"
#   echo "CLuster Deployment CRD conditions"
#   oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -ojson \
#      | jq -r '.status.conditions[]? | "\(.type)=\(.status) \(.reason) \(.message)"' || true
#   echo
#   echo "[Recent events]"
#   oc -n "$CLUSTER_NAME" get events --sort-by=.lastTimestamp | tail -n 30 || true
#   echo
#   echo "[ClusterProvisions]"
#   oc -n "$CLUSTER_NAME" get clusterprovisions -l hive.openshift.io/cluster-deployment-name="$CLUSTER_NAME" || true
#   echo
#   echo "[Provision pod logs (tail)]"
#   provPod=$(oc -n "$CLUSTER_NAME" get pod -l hive.openshift.io/job-type=provision -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
#   if [[ -n "${provPod:-}" ]]; then
#      oc -n "$CLUSTER_NAME" logs "$provPod" -c installer --tail=200 || true
#   else
#      echo "No provision pod found"
#   fi
#   echo "==================================="
# }



#monitor install untill success/fail/timeout
# while true; do
#   installed=$(oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -o jsonpath='{.spec.installed}' 2>/dev/null || echo "")
#   if [[ "$installed" == "true" ]]; then
#      echo "[INFO] $(now) Install complete: spec.installed=true"
#      break
#   fi

#   # check for terminal failure:
#   reason=$(oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -o json \
#     | jq -r '.status.condition[]? | select(.type=="ProvisionStopped" and .status=="True") | .reason' || true)
#   if [[ "${reason:-}" ]]; then
#      echo "[ERROR] Provision stopped (reason=${reason})."
#      dump_diag; exit 2
#   fi
#   #progress hints
#   msg=$(oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -o json \
#     | jq -r '.status.conditions[]? | select(.type=="ProvisionSucceeded" or .type=="ProvisionStopped" or .type=="RequirementsMet" or .type=="Provisioned" or .type=="InstallImagesNotResolved" or .type=="ProvisionFailed") | "\(.type): \(.status) \| \(.reason)  \| \(.message)"' | tr '\n' ' ' || true)
#   [[ -n "${msg:-}" ]] && echo "[INFO] $(now) ${msg}"
  
#   if (( $(date +%s) > deadline )); then
#     echo "[ERROR] install timed out after ${INSTALL_TIMEOUT_MINUTES} minutes"
#     dump_diag; exit 3
#   fi
#   sleep "$POLL_SECONDS"
# done

# fetch kubeconfig on success
KUBE_SECRET=$(oc -n "$CLUSTER_NAME" get clusterprovision -o json \
  | jq -r '.items | sort_by(.metadata.creationTimestamp)[-1].spec.adminKubeconfigSecretRef.name')
if [[ -z "${KUBE_SECRET:-}" || "${KUBE_SECRET:-null}" == "null" ]]; then
  echo "[WARN] adminKubeconfigSecret not found on latest ClusterProvision"
fi


OUT_KUBECONFIG="/tmp/${CLUSTER_NAME}-kubeconfig"
if [[ -f "$OUT_KUBECONFIG" ]]; then
  echo "[INFO] kubeconfig file $OUT_KUBECONFIG already exists; overwriting"
fi
oc -n "$CLUSTER_NAME" get secret "$KUBE_SECRET" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$OUT_KUBECONFIG"
echo "[INFO] kubeconfig saved to : ${OUT_KUBECONFIG}"
echo "[INFO] Try: KUBECONFIG=${OUT_KUBECONFIG} oc get nodes"

echo -n "${CLUSTER_NAME}" > "${SHARED_DIR}/managed.cluster.name"
cp $OUT_KUBECONFIG ${SHARED_DIR}/managed-cluster-kubeconfig

#show console url
CONSOLE_URL=$(oc -n "$CLUSTER_NAME" get clusterdeployment "$CLUSTER_NAME" -o jsonpath='{.status.webConsoleURL}' 2>/dev/null || true)
[[ -n "${CONSOLE_URL:-}" ]] && echo "[INFO] Web Console: ${CONSOLE_URL}"
echo "[INFO] $(now) Done."