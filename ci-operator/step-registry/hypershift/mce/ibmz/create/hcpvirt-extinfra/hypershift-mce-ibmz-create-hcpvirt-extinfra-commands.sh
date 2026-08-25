#!/bin/bash

set -x
set -e

# --- Step 0: Download the hcp CLI ---
echo "$(date) Installing hcp CLI"
mkdir -p /tmp/hcp_cli
downloadURL=$(oc get ConsoleCLIDownload hcp-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/hcp.tar.gz ${downloadURL}
tar -xvf /tmp/hcp.tar.gz -C /tmp/hcp_cli
chmod +x /tmp/hcp_cli/hcp
export PATH=$PATH:/tmp/hcp_cli
hcp version

# --- Step 1: Login to infra cluster and create the external infra namespace ---
echo "$(date) Logging in to infra cluster"
export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
oc new-project ext-infra-vms-ns

# --- Step 2: Switch to management cluster ---
echo "$(date) Switching to management cluster"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Enable Wildcard DNS Routes in OpenShift
oc patch ingresscontroller -n openshift-ingress-operator default \
  --type=json \
    -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

set +x
# Setting up pull secret
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
cp /tmp/.dockerconfigjson /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Hosted Control Plane parameters
HC_NAME=hcpvirt-oz-ci
HC_NS=hcpvirt-oz-ci-ns

hcp create cluster kubevirt \
  --name ${HC_NAME} \
  --node-pool-replicas 2 \
  --pull-secret "${PULL_SECRET_FILE}" \
  --namespace ${HC_NS} \
  --base-domain phc-cicd.cis.ibm.net \
  --control-plane-availability-policy SingleReplica \
  --arch s390x \
  --memory 16Gi \
  --cores 4 \
  --root-volume-size 60 \
  --infra-namespace=ext-infra-vms-ns \
  --infra-kubeconfig-file="${SHARED_DIR}/infra-kubeconfig" \
  --release-image ${OCP_IMAGE_MULTI} 


oc wait --timeout=25m --for=condition=Available --namespace=${HC_NS} hostedcluster/${HC_NAME}
echo "$(date) Kubevirt cluster is available"

# --- Step 3: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/virt-kubeconfig"

# --- Step 4: Wait for 2 worker nodes to join (with metallb speaker rollout on failure) ---
echo "$(date) Waiting for 2 worker nodes to join the guest cluster"

VIRT_KC="${SHARED_DIR}/virt-kubeconfig"
REQUIRED_NODES=2
MAX_RETRIES=10

wait_for_nodes() {
  local retries=0
  while [[ ${retries} -lt ${MAX_RETRIES} ]]; do
    READY_NODES=$(oc get no --kubeconfig "${VIRT_KC}" --no-headers 2>/dev/null \
      | grep -c " Ready" || true)
    echo "$(date) Ready nodes: ${READY_NODES}/${REQUIRED_NODES}"
    if [[ ${READY_NODES} -ge ${REQUIRED_NODES} ]]; then
      echo "$(date) ${REQUIRED_NODES} nodes are Ready"
      return 0
    fi

    # If kubeconfig is not yet accessible or nodes not ready, restart metallb speaker
    echo "$(date) Nodes not ready yet — restarting metallb speaker daemonset and retrying"
    export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
    oc rollout restart daemonset speaker -n metallb-system || true
    oc rollout status daemonset speaker -n metallb-system --timeout=60s || true
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"

    echo "$(date) Waiting 60s before retrying node check (attempt $((retries + 1))/${MAX_RETRIES})"
    sleep 60
    retries=$((retries + 1))
  done
  echo "$(date) ERROR: Timed out waiting for ${REQUIRED_NODES} nodes to be Ready"
  return 1
}

wait_for_nodes

# --- Step 5: Retrieve NodePort values for the guest cluster ingress ---
echo "$(date) Retrieving NodePort values from guest cluster ingress service"

HTTP_PORT=$(oc --kubeconfig "${VIRT_KC}" get services -n openshift-ingress router-nodeport-default \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
HTTPS_PORT=$(oc --kubeconfig "${VIRT_KC}" get services -n openshift-ingress router-nodeport-default \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "$(date) HTTP NodePort: ${HTTP_PORT}, HTTPS NodePort: ${HTTPS_PORT}"

# --- Step 6: Create LoadBalancer Service on the infra cluster ---
echo "$(date) Creating LoadBalancer Service on infra cluster (ext-infra-vms-ns)"
export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"

oc apply -f - <<SVCEOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: test-apps
  name: test-apps
  namespace: ext-infra-vms-ns
spec:
  ports:
  - name: https-443
    port: 443
    protocol: TCP
    targetPort: ${HTTPS_PORT}
  - name: http-80
    port: 80
    protocol: TCP
    targetPort: ${HTTP_PORT}
  selector:
    kubevirt.io: virt-launcher
  type: LoadBalancer
SVCEOF

# --- Step 7: Verify the LoadBalancer Service has the expected external IP ---
echo "$(date) Verifying LoadBalancer Service external IP"
EXPECTED_LB_IP="192.168.2.54"
LB_TIMEOUT=120
LB_INTERVAL=10
LB_ELAPSED=0

ASSIGNED_IP=""
while [[ ${LB_ELAPSED} -lt ${LB_TIMEOUT} ]]; do
  ASSIGNED_IP=$(oc get svc test-apps -n ext-infra-vms-ns \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ "${ASSIGNED_IP}" == "${EXPECTED_LB_IP}" ]]; then
    echo "$(date) LoadBalancer Service has expected IP: ${ASSIGNED_IP}"
    break
  fi
  echo "$(date) Waiting for LoadBalancer IP ${EXPECTED_LB_IP}, current: '${ASSIGNED_IP}' (${LB_ELAPSED}s elapsed)"
  sleep ${LB_INTERVAL}
  LB_ELAPSED=$((LB_ELAPSED + LB_INTERVAL))
done

if [[ "${ASSIGNED_IP}" != "${EXPECTED_LB_IP}" ]]; then
  echo "$(date) ERROR: LoadBalancer Service IP is '${ASSIGNED_IP}', expected '${EXPECTED_LB_IP}'"
  exit 1
fi

# --- Step 8: Wait for all ClusterOperators to be Available=True and Degraded=False ---
echo "$(date) Waiting for all ClusterOperators to be Available and not Degraded"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

CO_MAX_WAIT=1800  # 30 minutes in seconds
CO_INTERVAL=30
CO_ELAPSED=0
UNAVAILABLE=""

while [[ ${CO_ELAPSED} -lt ${CO_MAX_WAIT} ]]; do
  UNAVAILABLE=$(oc get co --kubeconfig "${VIRT_KC}" --no-headers 2>/dev/null \
    | awk '{print $3, $5}' \
    | grep -v "^True False$" || true)
  if [[ -z "${UNAVAILABLE}" ]]; then
    echo "$(date) All ClusterOperators are Available=True and Degraded=False"
    break
  fi
  echo "$(date) ClusterOperators not yet healthy (${CO_ELAPSED}s elapsed):"
  echo "${UNAVAILABLE}"
  sleep ${CO_INTERVAL}
  CO_ELAPSED=$((CO_ELAPSED + CO_INTERVAL))
done

if [[ -n "${UNAVAILABLE}" ]]; then
  echo "$(date) ERROR: Some ClusterOperators are not Available or are Degraded:"
  oc get co --kubeconfig "${VIRT_KC}"
  exit 1
fi

echo "$(date) HCP virt - external infra cluster is fully operational"
