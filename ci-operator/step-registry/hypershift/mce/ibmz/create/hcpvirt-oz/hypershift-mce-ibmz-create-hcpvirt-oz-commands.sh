#!/bin/bash

set -x
set -e

# --- Step 0: Download and install the hcp CLI ---
echo "$(date) Installing hcp CLI"
mkdir -p /tmp/hcp_cli
downloadURL=$(oc get ConsoleCLIDownload hcp-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/hcp.tar.gz ${downloadURL}
tar -xvf /tmp/hcp.tar.gz -C /tmp/hcp_cli
chmod +x /tmp/hcp_cli/hcp
export PATH=$PATH:/tmp/hcp_cli
hcp version

# --- Step 1: Prepare management cluster and create the HCP KubeVirt hosted cluster ---
# The management cluster hosts both the HCP control plane pods and the KubeVirt VMs (worker nodes).
echo "$(date) Targeting management cluster kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Enable wildcard DNS routes so guest *.apps routes resolve through the management ingress
oc patch ingresscontroller -n openshift-ingress-operator default \
  --type=json \
    -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

set +x
# Extract the management cluster pull secret for use when provisioning the hosted cluster
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
cp /tmp/.dockerconfigjson /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Hosted cluster identity and namespace
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
  --release-image ${OCP_IMAGE_MULTI}

oc wait --timeout=45m --for=condition=Available --namespace=hcpvirt-oz-ci-ns hostedclusters.hypershift.openshift.io/hcpvirt-oz-ci
echo "$(date) Kubevirt cluster is available"

# --- Step 2: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"

# Persist management cluster kubeconfig separately so conformance steps can reference it
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

# Allow time for the KubeVirt VMs to be scheduled and begin booting before polling nodes
echo "$(date) Sleeping 20 minutes to allow KubeVirt VMs to boot before checking node readiness..."
sleep 1200
echo "$(date) Sleep complete, proceeding to node readiness check"

# --- Step 3: Wait for KubeVirt worker VMs to boot and join the guest cluster as Ready nodes ---
echo "$(date) Waiting for 2 worker nodes to join the guest cluster"

VIRT_KC="${SHARED_DIR}/nested_kubeconfig"
REQUIRED_NODES=2
MAX_RETRIES=20


# Restart MetalLB speaker daemonset once before the wait loop to trigger fresh ARP announcements
# (needed on SNO management clusters where the speaker may not have announced the LB IP yet)
echo "$(date) Restarting MetalLB speaker daemonset on management cluster once..."
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc get pods -n metallb-system 2>/dev/null || true
oc rollout restart daemonset speaker -n metallb-system || true
oc rollout status daemonset speaker -n metallb-system --timeout=120s || true

echo "$(date) Nodepool status........"
oc get np -A
oc describe np -A

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

    echo "$(date) Nodes not ready yet — printing debug status"
    echo "$(date) DEBUG: All nodes in guest cluster:"
    oc get no --kubeconfig "${VIRT_KC}" -o wide 2>/dev/null || echo "  (kubeconfig not yet accessible)"
    echo "$(date) DEBUG: KubeVirt VMs on mgmt cluster:"
    oc get vmi -n ${HC_NS}-${HC_NAME} 2>/dev/null || true

    echo "$(date) Waiting 60s before retrying node check (attempt $((retries + 1))/${MAX_RETRIES})"
    sleep 60
    retries=$((retries + 1))
  done
  echo "$(date) ERROR: Timed out waiting for ${REQUIRED_NODES} nodes to be Ready after ${MAX_RETRIES} retries"
  echo "$(date) DEBUG: Final management cluster state:"
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc get no || true
  oc get hc -A || true
  oc describe hc -n ${HC_NS} ${HC_NAME} || true
  oc get np -A || true
  oc describe np -n ${HC_NS} || true
  oc get po -n ${HC_NS}-${HC_NAME} || true
  oc get vmi -A || true
  oc describe vmi -A || true
  return 1
}

wait_for_nodes

# --- Step 4: Read NodePort values from the guest cluster's default ingress service ---
# The guest cluster uses a NodePort-type router; we need the assigned ports to wire up
# the management-side LoadBalancer service that exposes *.apps externally.
echo "$(date) Retrieving NodePort values from guest cluster ingress service"

HTTP_PORT=$(oc --kubeconfig "${VIRT_KC}" get services -n openshift-ingress router-nodeport-default \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
HTTPS_PORT=$(oc --kubeconfig "${VIRT_KC}" get services -n openshift-ingress router-nodeport-default \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "$(date) HTTP NodePort: ${HTTP_PORT}, HTTPS NodePort: ${HTTPS_PORT}"

# --- Step 5: Create a LoadBalancer Service on the management cluster to expose guest *.apps traffic ---
# This Service selects the KubeVirt VM pods (virt-launcher) and forwards port 80/443 to the
# guest cluster's NodePort ingress, giving the hosted cluster a reachable external ingress.
echo "$(date) Creating *.apps LoadBalancer Service targeting KubeVirt VM pods"

oc apply -f - <<SVCEOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: test-apps
  name: test-apps
  namespace: ${HC_NS}-${HC_NAME}
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


# --- Step 6: Wait for all guest cluster ClusterOperators to be Available and not Degraded ---
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
  echo "$(date) DEBUG: Degraded CO details:"
  oc get co --kubeconfig "${VIRT_KC}" -o yaml || true
  echo "$(date) DEBUG: Guest cluster nodes:"
  oc get no --kubeconfig "${VIRT_KC}" -o wide || true
  echo "$(date) DEBUG: Guest cluster pods with issues:"
  oc get pods -A --kubeconfig "${VIRT_KC}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true

  echo "$(date) DEBUG: Management cluster state at CO failure"
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc get no || true
  oc get hc -A || true
  oc describe hc -n ${HC_NS} ${HC_NAME} || true
  oc get np -A || true
  oc describe np -n ${HC_NS} || true
  oc get po -n ${HC_NS}-${HC_NAME} || true
  oc get vmi -A || true
  oc describe vmi -A || true
  
  exit 1
fi

echo "$(date) HCP KubeVirt hosted cluster is fully operational"

# --- Step 7: Switch KUBECONFIG to the guest cluster for downstream conformance steps ---
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
