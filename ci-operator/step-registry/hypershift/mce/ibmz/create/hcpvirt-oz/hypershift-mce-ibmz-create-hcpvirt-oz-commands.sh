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
    -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {"wildcardPolicy": "WildcardsAllowed"}}]'

set +x
# Extract the management cluster pull secret for use when provisioning the hosted cluster
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
cp /tmp/.dockerconfigjson /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Restrict virt VMs on compute nodes
#for node in compute-0 compute-1; do
#  oc label node "${node}" role=kubevirt --overwrite
#done
#oc get nodes -l role=kubevirt
# Hosted cluster identity and namespace — derived from the MetalLB IPAddressPool range
POOL_RANGE=$(oc get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || true)
echo "$(date) MetalLB IPAddressPool range: ${POOL_RANGE}"

if [[ "${POOL_RANGE}" == 192.168.2.* ]]; then
  HC_NAME=hcpvirt-oz-ci
  HC_NS=hcpvirt-oz-ci-ns
elif [[ "${POOL_RANGE}" == 192.168.3.* ]]; then
  HC_NAME=hcpvirtnew-oz-ci
  HC_NS=hcpvirtnew-oz-ci-ns
else
  echo "$(date) ERROR: Unrecognised IPAddressPool range '${POOL_RANGE}', expected 192.168.2.x or 192.168.3.x"
  exit 1
fi

echo "$(date) Using HC_NAME=${HC_NAME}, HC_NS=${HC_NS}"
MGMT_HOST_IP=10.0.1.15
echo "$(date) LPAR host IP: ${MGMT_HOST_IP}"


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
  --release-image ${OCP_IMAGE_MULTI} \
  --annotations "resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-scheduler.kube-scheduler=memory=512Mi,cpu=500m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-controller-manager.kube-controller-manager=memory=1Gi,cpu=1000m" 
 #--vm-node-selector role=kubevirt \
oc wait --timeout=45m --for=condition=Available --namespace="${HC_NS}" hostedclusters.hypershift.openshift.io/"${HC_NAME}"
echo "$(date) Kubevirt cluster is available"

# --- Step 2: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"

# Persist management cluster kubeconfig separately so conformance steps can reference it
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

# Persist cluster identity so hypershift-conformance-chain can resolve
# HYPERSHIFT_MANAGEMENT_CLUSTER_NAMESPACE correctly.
# The conformance chain derives CLUSTER_NAME from PROW_JOB_ID (sha256), which does
# not match our static HC_NAME. Writing these files lets the chain use the real name.
echo -n "${HC_NAME}" > "${SHARED_DIR}/cluster-name"
echo -n "${HC_NS}"   > "${SHARED_DIR}/cluster-namespace"

# Allow time for the KubeVirt VMs to be scheduled and begin booting before polling nodes
echo "$(date) Sleeping 20 minutes to allow KubeVirt VMs to boot before checking node readiness..."
sleep 1200
echo "$(date) Sleep complete, proceeding to node readiness check"

# --- Step 3: Wait for KubeVirt worker VMs to boot and join the guest cluster as Ready nodes ---
echo "$(date) Waiting for 2 worker nodes to join the guest cluster"

VIRT_KC="${SHARED_DIR}/nested_kubeconfig"
REQUIRED_NODES=2
MAX_RETRIES=20

# --- Wait for kube-apiserver NodePort ---
# HyperShift assigns the NodePort asynchronously after the HostedCluster becomes
# Available — retry until it appears rather than sampling once.
NODEPORT=""
for i in {1..30}; do
  NODEPORT=$(oc get svc kube-apiserver -n "${HC_NS}-${HC_NAME}" \
    -o jsonpath="{.spec.ports[?(@.port==6443)].nodePort}" 2>/dev/null || true)
  [[ -n "${NODEPORT}" ]] && break
  echo "$(date) kube-apiserver NodePort not ready yet, retrying... ($i/30)"
  sleep 10
done
if [[ -z "${NODEPORT}" ]]; then
  echo "$(date) ERROR: kube-apiserver NodePort never appeared — aborting"
  oc get svc -n "${HC_NS}-${HC_NAME}" || true
  exit 1
fi
echo "$(date) kube-apiserver NodePort: ${NODEPORT}"

# --- Patch nested kubeconfig to use the reachable LPAR IP + NodePort ---
# The kubeconfig written by 'hcp create kubeconfig' contains an internal cluster
# address; replace it with the LPAR host IP that the CI runner pod can reach.
# --insecure-skip-tls-verify is required because the kube-apiserver TLS cert is
# issued for the cluster's internal DNS name, not for MGMT_HOST_IP.
CLSTR_NAME=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].name}')
oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
  --server="https://${MGMT_HOST_IP}:${NODEPORT}" \
  --insecure-skip-tls-verify=true
echo "$(date) Patched nested_kubeconfig server → https://${MGMT_HOST_IP}:${NODEPORT}"

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

  # --- Check kube-apiserver reachability via /readyz before polling nodes ---
  READYZ_RESPONSE=$(curl -sk "https://${MGMT_HOST_IP}:${NODEPORT}/readyz" 2>&1 || true)
  echo "$(date) /readyz response: ${READYZ_RESPONSE}"
  if [[ "${READYZ_RESPONSE}" == "ok" ]]; then
    echo "$(date) kube-apiserver is reachable and ready"
  else
    echo "$(date) WARNING: kube-apiserver /readyz did not return 'ok' — API may not be reachable yet"
  fi

  while [[ ${retries} -lt ${MAX_RETRIES} ]]; do
    # --- Per-retry reachability check ---
    READYZ=$(curl -sk "https://${MGMT_HOST_IP}:${NODEPORT}/readyz" 2>&1 || true)
    echo "$(date) [retry ${retries}] /readyz: ${READYZ}"

    READY_NODES=$(oc get no --kubeconfig "${VIRT_KC}" --no-headers --request-timeout=300s 2>/dev/null \
      | grep -c " Ready" || true)
    echo "$(date) Ready nodes: ${READY_NODES}/${REQUIRED_NODES}"
    if [[ ${READY_NODES} -ge ${REQUIRED_NODES} ]]; then
      echo "$(date) ${REQUIRED_NODES} nodes are Ready"
      oc get no --kubeconfig "${VIRT_KC}" -o wide --request-timeout=300s -v6
      return 0
    fi

    echo "$(date) Nodes not ready yet — printing debug status"
    echo "$(date) DEBUG: All nodes in guest cluster:"
    oc get no --kubeconfig "${VIRT_KC}" -o wide --request-timeout=300s || true
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
# The guest cluster router listens on NodePorts, not 80/443 directly.
# We need these ports as targetPorts for the management-side LoadBalancer service.
echo "$(date) Retrieving NodePort values from guest cluster ingress service"

HTTP_PORT=$(oc --kubeconfig "${VIRT_KC}" get services -n openshift-ingress router-nodeport-default \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
HTTPS_PORT=$(oc --kubeconfig "${VIRT_KC}" get services -n openshift-ingress router-nodeport-default \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "$(date) HTTP NodePort: ${HTTP_PORT}, HTTPS NodePort: ${HTTPS_PORT}"

# --- Step 5: Create a LoadBalancer Service on the management cluster to expose guest *.apps traffic ---
# Selects KubeVirt VM pods (virt-launcher) and forwards port 80/443 to the guest router NodePorts.
echo "$(date) Creating *.apps LoadBalancer Service targeting KubeVirt VM pods"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

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

# --- Step 5b: Wait for MetalLB EXTERNAL-IP and bypass konnectivity for ingress canary ---
# Ingress-operator (CP on mgmt) health-checks *.apps via HTTPS_PROXY=127.0.0.1:8090
# (konnectivity). On this OZ/libvirt+MetalLB topology, CONNECT to the apps VIP hangs
# even though direct curls from mgmt CP pods and guest hosts succeed. Extending
# NO_PROXY so canary dials the LB directly clears CanaryChecksSucceeding / ingress Degraded.
# Do NOT set guest Proxy noProxy-only — that invalidates proxy.config.openshift.io.
echo "$(date) Waiting for test-apps LoadBalancer EXTERNAL-IP"
LB_IP=""
for i in {1..60}; do
  LB_IP=$(oc get svc test-apps -n "${HC_NS}-${HC_NAME}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${LB_IP}" && "${LB_IP}" != "<pending>" ]]; then
    break
  fi
  echo "$(date) test-apps EXTERNAL-IP not ready yet, retrying... ($i/60)"
  sleep 5
done
if [[ -z "${LB_IP}" || "${LB_IP}" == "<pending>" ]]; then
  echo "$(date) ERROR: test-apps never received an EXTERNAL-IP"
  oc get svc test-apps -n "${HC_NS}-${HC_NAME}" -o yaml || true
  exit 1
fi
echo "$(date) test-apps EXTERNAL-IP: ${LB_IP}"

APPS_DOMAIN="apps.${HC_NAME}.phc-cicd.cis.ibm.net"
CANARY_URL="https://canary-openshift-ingress-canary.${APPS_DOMAIN}"
CP_NS="${HC_NS}-${HC_NAME}"

echo "$(date) Setting ingress-operator NO_PROXY so canary bypasses konnectivity for ${APPS_DOMAIN}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc set env deploy/ingress-operator -n "${CP_NS}" -c ingress-operator \
  "NO_PROXY=kube-apiserver,${LB_IP},.${APPS_DOMAIN},phc-cicd.cis.ibm.net,127.0.0.1,localhost"
oc rollout status deploy/ingress-operator -n "${CP_NS}" --timeout=120s

echo "$(date) Verifying canary URL from ingress-operator without konnectivity proxy"
oc exec -n "${CP_NS}" deploy/ingress-operator -c ingress-operator -- \
  curl -vk --connect-timeout 10 "${CANARY_URL}" || true

echo "$(date) Waiting for CanaryChecksSucceeding on default IngressController"
CANARY_WAIT=300
CANARY_ELAPSED=0
while [[ ${CANARY_ELAPSED} -lt ${CANARY_WAIT} ]]; do
  CANARY_STATUS=$(oc get ingresscontroller default -n openshift-ingress-operator \
    --kubeconfig "${VIRT_KC}" \
    -o jsonpath='{.status.conditions[?(@.type=="CanaryChecksSucceeding")].status}' 2>/dev/null || true)
  if [[ "${CANARY_STATUS}" == "True" ]]; then
    echo "$(date) CanaryChecksSucceeding=True"
    break
  fi
  echo "$(date) CanaryChecksSucceeding=${CANARY_STATUS:-unknown} (${CANARY_ELAPSED}s/${CANARY_WAIT}s)"
  sleep 30
  CANARY_ELAPSED=$((CANARY_ELAPSED + 30))
done
oc get co ingress --kubeconfig "${VIRT_KC}" || true
oc get ingresscontroller default -n openshift-ingress-operator \
  --kubeconfig "${VIRT_KC}" \
  -o jsonpath='{.status.conditions[?(@.type=="CanaryChecksSucceeding")]}{"\n"}' || true

# --- Step 6: Wait for all guest cluster ClusterOperators to be Available ---
echo "$(date) Waiting for all ClusterOperators to be Available"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

CO_MAX_WAIT=1800  # 30 minutes in seconds
CO_INTERVAL=30
CO_ELAPSED=0
UNAVAILABLE=""

while [[ ${CO_ELAPSED} -lt ${CO_MAX_WAIT} ]]; do
  UNAVAILABLE=$(oc get co --kubeconfig "${VIRT_KC}" --no-headers 2>/dev/null \
    | awk '{print $3}' \
    | grep -v "^True$" || true)
  if [[ -z "${UNAVAILABLE}" ]]; then
    echo "$(date) All ClusterOperators are Available=True"
    break
  fi
  echo "$(date) ClusterOperators not yet healthy (${CO_ELAPSED}s elapsed):"
  echo "${UNAVAILABLE}"
  sleep ${CO_INTERVAL}
  CO_ELAPSED=$((CO_ELAPSED + CO_INTERVAL))
done

if [[ -n "${UNAVAILABLE}" ]]; then
  echo "$(date) ERROR: Some ClusterOperators are not Available:"
  oc get co --kubeconfig "${VIRT_KC}"
  echo "$(date) DEBUG: Degraded CO details:"
  oc get co --kubeconfig "${VIRT_KC}" -o yaml || true
  echo "$(date) DEBUG: Guest cluster nodes:"
  oc get no --kubeconfig "${VIRT_KC}" -o wide --request-timeout=300s || true
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

# Print control-plane workload resource requests regardless of pass/fail
echo "$(date) Control-plane deploy/statefulset resource requests:"
oc get deploy,statefulset -n ${HC_NS}-${HC_NAME} \
  --kubeconfig="${SHARED_DIR}/kubeconfig" \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEM:.spec.template.spec.containers[0].resources.requests.memory' || true

# --- Step 10: Switch KUBECONFIG to the guest cluster for downstream conformance steps ---
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
