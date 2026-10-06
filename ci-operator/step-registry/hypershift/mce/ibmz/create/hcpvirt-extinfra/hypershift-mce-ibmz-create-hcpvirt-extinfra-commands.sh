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

# Hosted cluster identity and namespace — derived from the MetalLB IPAddressPool range
POOL_RANGE=$(oc get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || true)
echo "$(date) MetalLB IPAddressPool range: ${POOL_RANGE}"

if [[ "${POOL_RANGE}" == 192.168.2.* ]]; then
  HC_NAME=hcpvirt-oz-ci
  HC_NS=hcpvirt-oz-ci-ns
  MGMT_CLUSTER_LEASE=3-2
elif [[ "${POOL_RANGE}" == 192.168.3.* ]]; then
  HC_NAME=hcpvirtnew-oz-ci
  HC_NS=hcpvirtnew-oz-ci-ns
  MGMT_CLUSTER_LEASE=3-3
else
  echo "$(date) ERROR: Unrecognised IPAddressPool range '${POOL_RANGE}', expected 192.168.2.x or 192.168.3.x"
  exit 1
fi

# Restrict guest worker VM placement to infra nodes with working API connectivity.
# control-0 (10.8.x) cannot reach the guest API NodePort from the LPAR host path.
# Label matches hcp --vm-node-selector format (key=value on infra nodes).
#for node in control-1 control-2; do
# oc label node "${node}" role=kubevirt --overwrite
#done
#oc get nodes -l role=kubevirt

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

# The LPAR host IP (10.0.1.15) is the NAT gateway for the libvirt bridge and is
# reachable from the CI runner pod via haproxy. We pin the kube-apiserver Service
# to a fixed NodePort so the nested kubeconfig can point at MGMT_HOST_IP:FIXED_NODEPORT.
echo "$(date) Using HC_NAME=${HC_NAME}, HC_NS=${HC_NS}"
MGMT_HOST_IP=10.0.1.15
echo "$(date) LPAR host IP: ${MGMT_HOST_IP}"

if [[ "${MGMT_CLUSTER_LEASE}" == "3-2" ]]; then
  FIXED_NODEPORT=31132
elif [[ "${MGMT_CLUSTER_LEASE}" == "3-3" ]]; then
  FIXED_NODEPORT=31133
else
  echo "$(date) ERROR: unknown MGMT_CLUSTER_LEASE '${MGMT_CLUSTER_LEASE}'"
  exit 1
fi
echo "$(date) Fixed NodePort for lease ${MGMT_CLUSTER_LEASE}: ${FIXED_NODEPORT}"

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
  --release-image ${OCP_IMAGE_MULTI} \
  --annotations "resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-scheduler.kube-scheduler=memory=512Mi,cpu=500m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-controller-manager.kube-controller-manager=memory=1Gi,cpu=1000m"

echo "$(date) HCP cluster created"

# --- Pin the kube-apiserver Service NodePort to FIXED_NODEPORT ---
# HyperShift creates a LoadBalancer Service named "kube-apiserver" in the
# control-plane namespace (HC_NS-HC_NAME) shortly after the HostedCluster is
# applied. We wait for it to appear, then patch its port entry to the fixed
# NodePort that haproxy on the LPAR has pre-configured. MetalLB continues to
# manage the VIP; only the nodePort field is pinned.
KAPI_SVC_NS="${HC_NS}-${HC_NAME}"
KAPI_SVC_NAME="kube-apiserver"

echo "$(date) Waiting for Service ${KAPI_SVC_NAME} to appear in ${KAPI_SVC_NS}"
for i in {1..60}; do
  if oc get svc "${KAPI_SVC_NAME}" -n "${KAPI_SVC_NS}" &>/dev/null; then
    echo "$(date) Service ${KAPI_SVC_NAME} found (attempt ${i})"
    break
  fi
  echo "$(date) Service not yet present, waiting 10s... (${i}/60)"
  sleep 10
done

if ! oc get svc "${KAPI_SVC_NAME}" -n "${KAPI_SVC_NS}" &>/dev/null; then
  echo "$(date) ERROR: Service ${KAPI_SVC_NAME} did not appear within 10 minutes"
  exit 1
fi

echo "$(date) Patching ${KAPI_SVC_NAME} port[0].nodePort → ${FIXED_NODEPORT}"
oc patch svc "${KAPI_SVC_NAME}" -n "${KAPI_SVC_NS}" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${FIXED_NODEPORT}}]"
echo "$(date) NodePort pinned to ${FIXED_NODEPORT} on Service ${KAPI_SVC_NAME}"

echo "$(date) DEBUG: Sleeping 40 minutes after hcp create to let HC and NodePool settle"
sleep 2400

echo "$(date) DEBUG: Management cluster state after 40m sleep"
oc get no || true
oc get hc -A || true
oc describe hc -n ${HC_NS} ${HC_NAME} || true
oc get hc -n ${HC_NS} ${HC_NAME} -o jsonpath='{.status.conditions}' | jq . || true
echo "$(date) DEBUG: NodePool status"
oc get np -A || true
oc describe np -n ${HC_NS} || true
oc get nodepool -n ${HC_NS} -o yaml || true
echo "$(date) DEBUG: HCP control plane pods"
oc get po -n ${HC_NS}-${HC_NAME} || true
echo "$(date) DEBUG: capi-provider pod describe, logs, and deployment details"
CAPI_PODS=$(oc get po -n ${HC_NS}-${HC_NAME} --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E '^capi-provider|^capi-' || true)
if [[ -n "${CAPI_PODS}" ]]; then
  for p in ${CAPI_PODS}; do
    echo "$(date) --- oc describe pod ${p} ---"
    oc describe po -n ${HC_NS}-${HC_NAME} "${p}" || true
    echo "$(date) --- oc logs pod ${p} (all containers) ---"
    oc logs -n ${HC_NS}-${HC_NAME} "${p}" --all-containers=true --tail=200 || true
    echo "$(date) --- oc logs pod ${p} (previous if restarted) ---"
    oc logs -n ${HC_NS}-${HC_NAME} "${p}" --all-containers=true --previous=true --tail=100 || true
  done
else
  echo "$(date) No capi-provider pod found matching prefix in ${HC_NS}-${HC_NAME}"
fi
echo "$(date) --- describe capi-provider deployment ---"
oc describe deployment capi-provider -n ${HC_NS}-${HC_NAME} || true
echo "$(date) --- all events in control plane namespace ---"
oc get events -n ${HC_NS}-${HC_NAME} --sort-by='.lastTimestamp' | tail -50 || true

echo "$(date) DEBUG: Infra cluster nodes and VMIs after 20m sleep"
export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
oc get no || true
oc get vmi -A || true
oc describe vmi -A || true
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

oc wait --timeout=45m --for=condition=Available --namespace="${HC_NS}" hostedclusters.hypershift.openshift.io/"${HC_NAME}"
echo "$(date) Kubevirt cluster is available"

# --- Step 3: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"

# Save mgmt kubeconfig so hypershift-conformance chain picks it up via mgmt_kubeconfig
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

# Persist cluster identity so hypershift-conformance-chain can resolve
# HYPERSHIFT_MANAGEMENT_CLUSTER_NAMESPACE correctly.
# The conformance chain derives CLUSTER_NAME from PROW_JOB_ID (sha256), which does
# not match our static HC_NAME. Writing these files lets the chain use the real name.
echo -n "${HC_NAME}" > "${SHARED_DIR}/cluster-name"
echo -n "${HC_NS}"   > "${SHARED_DIR}/cluster-namespace"

# --- Step 3: Wait for KubeVirt worker VMs to boot and join the guest cluster as Ready nodes ---
echo "$(date) Waiting for 2 worker nodes to join the guest cluster"

VIRT_KC="${SHARED_DIR}/nested_kubeconfig"
REQUIRED_NODES=2
MAX_RETRIES=20

# NodePort is now fixed — use FIXED_NODEPORT directly (no polling needed).
NODEPORT="${FIXED_NODEPORT}"
echo "$(date) kube-apiserver NodePort (fixed): ${NODEPORT}"

# --- Patch nested kubeconfig to use the reachable LPAR IP + fixed NodePort ---
# The kubeconfig written by 'hcp create kubeconfig' contains an internal cluster
# address; replace it with the LPAR host IP that the CI runner pod can reach.
# --insecure-skip-tls-verify is required because the kube-apiserver TLS cert is
# issued for the cluster's internal DNS name, not for MGMT_HOST_IP.
CLSTR_NAME=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].name}')
oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
  --server="https://${MGMT_HOST_IP}:${NODEPORT}" \
  --insecure-skip-tls-verify=true
echo "$(date) Patched nested_kubeconfig server → https://${MGMT_HOST_IP}:${NODEPORT}"

# --- Verify the fixed NodePort is reachable via the LPAR haproxy ---
echo "$(date) Probing kube-apiserver via LPAR haproxy at ${MGMT_HOST_IP}:${NODEPORT}"
for i in {1..10}; do
  READYZ=$(curl -sk --connect-timeout 5 "https://${MGMT_HOST_IP}:${NODEPORT}/readyz" 2>/dev/null || true)
  echo "$(date) [probe ${i}/10] /readyz: ${READYZ}"
  [[ "${READYZ}" == "ok" ]] && break
  sleep 10
done

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
  export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
  oc get no || true
  oc get vmi -A || true
  oc describe vmi -A || true
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

# --- Step 5b: Wait for MetalLB EXTERNAL-IP and bypass konnectivity for ingress canary ---
# Ingress-operator (CP on mgmt) health-checks *.apps via HTTPS_PROXY=127.0.0.1:8090
# (konnectivity). On this OZ/libvirt+MetalLB topology, guest CoreDNS cannot reliably
# resolve external *.apps names for the konnectivity CONNECT path, so canary times out
# even though direct curls from mgmt CP pods succeed. Extending NO_PROXY makes canary
# dial the LB directly and clears CanaryChecksSucceeding / ingress Degraded.
# CPO owns deploy/ingress-operator and resets NO_PROXY to kube-apiserver only, so we
# pause the HostedCluster afterwards to keep the workaround stable through conformance.
# Do NOT set guest Proxy noProxy-only — that invalidates proxy.config.openshift.io.
echo "$(date) Waiting for test-apps LoadBalancer EXTERNAL-IP"
LB_IP=""
for i in {1..60}; do
  LB_IP=$(oc get svc test-apps -n ext-infra-vms-ns \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${LB_IP}" && "${LB_IP}" != "<pending>" ]]; then
    break
  fi
  echo "$(date) test-apps EXTERNAL-IP not ready yet, retrying... ($i/60)"
  sleep 5
done
if [[ -z "${LB_IP}" || "${LB_IP}" == "<pending>" ]]; then
  echo "$(date) ERROR: test-apps never received an EXTERNAL-IP"
  oc get svc test-apps -n ext-infra-vms-ns -o yaml || true
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

echo "$(date) Pausing HostedCluster ${HC_NS}/${HC_NAME} so CPO does not reset ingress-operator NO_PROXY"
oc patch hostedcluster "${HC_NAME}" -n "${HC_NS}" --type=merge \
  -p '{"spec":{"pausedUntil":"true"}}'
echo "$(date) HostedCluster pausedUntil=$(oc get hostedcluster "${HC_NAME}" -n "${HC_NS}" -o jsonpath='{.spec.pausedUntil}')"

# Confirm NO_PROXY still contains the LB IP after pause (CPO must not have wiped it)
NOPROXY_CUR=$(oc get deploy ingress-operator -n "${CP_NS}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="ingress-operator")].env[?(@.name=="NO_PROXY")].value}')
echo "$(date) ingress-operator NO_PROXY=${NOPROXY_CUR}"
if [[ "${NOPROXY_CUR}" != *"${LB_IP}"* ]]; then
  echo "$(date) WARNING: NO_PROXY missing ${LB_IP} after pause; re-applying"
  oc set env deploy/ingress-operator -n "${CP_NS}" -c ingress-operator \
    "NO_PROXY=kube-apiserver,${LB_IP},.${APPS_DOMAIN},phc-cicd.cis.ibm.net,127.0.0.1,localhost"
fi

oc rollout status deploy/ingress-operator -n "${CP_NS}" --timeout=120s

echo "$(date) Verifying canary URL from ingress-operator (should bypass konnectivity via NO_PROXY)"
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
  oc adm top pods -n ${HC_NS}-${HC_NAME} || true 
  export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
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

oc adm top pods -n ${HC_NS}-${HC_NAME} || true 

# --- Step 10: Switch KUBECONFIG to the guest cluster for downstream conformance steps ---
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
