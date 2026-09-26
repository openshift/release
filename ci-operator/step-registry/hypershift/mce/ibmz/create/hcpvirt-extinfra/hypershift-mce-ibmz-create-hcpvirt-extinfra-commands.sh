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

# Restrict guest worker VM placement to infra nodes with working API connectivity.
# control-0 (10.8.x) cannot reach the guest API NodePort from the LPAR host path.
# Label matches hcp --vm-node-selector format (key=value on infra nodes).
for node in control-1 control-2; do
  oc label node "${node}" role=kubevirt --overwrite
done
oc get nodes -l role=kubevirt

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

# Both mgmt and infra clusters are libvirt NAT bridges on the same LPAR (10.0.1.15).
# The two bridges (ocp2: 192.168.2.x, ocp3: 192.168.3.x) are L2-isolated — NAT mode
# does not route between them. The MetalLB VIP (192.168.2.x) is unreachable from the
# infra bridge, so VMIs can never fetch ignition using the default LoadBalancer address.
# The LPAR host IP (10.0.1.15) is reachable from both bridges as it is the NAT gateway.
MGMT_HOST_IP=10.0.1.15
echo "$(date) LPAR host IP: ${MGMT_HOST_IP}"

# --- Pre-flight: wait for the hypershift webhook endpoint to be live ---
# oc wait deployment Available=True does NOT guarantee the mutating webhook
# server is accepting connections. On s390x the 15m sleep in hypershift-mce-install
# is skipped (x86_64-only), so the endpoint may not be up yet.
echo "$(date) Waiting for hypershift operator webhook endpoint to become live..."
WEBHOOK_TIMEOUT=300
WEBHOOK_INTERVAL=10
WEBHOOK_ELAPSED=0
while [[ ${WEBHOOK_ELAPSED} -lt ${WEBHOOK_TIMEOUT} ]]; do
  READY=$(oc get endpoints operator -n hypershift \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [[ -n "${READY}" ]]; then
    echo "$(date) Hypershift operator webhook endpoint is live: ${READY}"
    break
  fi
  echo "$(date) Webhook endpoint not ready yet (${WEBHOOK_ELAPSED}s elapsed), retrying in ${WEBHOOK_INTERVAL}s..."
  sleep ${WEBHOOK_INTERVAL}
  WEBHOOK_ELAPSED=$((WEBHOOK_ELAPSED + WEBHOOK_INTERVAL))
done
if [[ -z "${READY}" ]]; then
  echo "$(date) ERROR: hypershift operator webhook endpoint did not become ready within ${WEBHOOK_TIMEOUT}s"
  echo "--- endpoints in hypershift ns ---"
  oc get endpoints -n hypershift || true
  echo "--- all pods in hypershift ns ---"
  oc get pods -n hypershift -o wide || true
  echo "--- describe operator deployment ---"
  oc describe deployment operator -n hypershift || true
  echo "--- operator pod logs (last 50 lines) ---"
  oc logs -n hypershift -l app=operator --tail=50 || true
  echo "--- operator pod events ---"
  oc get events -n hypershift --sort-by='.lastTimestamp' | tail -30 || true
  echo "--- webhook configurations targeting hypershift ---"
  oc get mutatingwebhookconfiguration -o json | jq '.items[] | select(.webhooks[]?.clientConfig.service.namespace == "hypershift") | {name: .metadata.name, webhooks: [.webhooks[].name]}' || true
  exit 1
fi

# --api-server-address does not exist on the kubevirt subcommand (agent-only flag).
# Instead, render the manifests first, patch the APIServer servicePublishingStrategy
# to NodePort with the LPAR host IP, then apply — same pattern as the agent script
# uses for s390x to switch from LoadBalancer to NodePort before apply.
mkdir -p /tmp/hc-manifests

hcp create cluster kubevirt \
  --name ${HC_NAME} \
  --node-pool-replicas 1 \
  --pull-secret "${PULL_SECRET_FILE}" \
  --namespace ${HC_NS} \
  --base-domain phc-cicd.cis.ibm.net \
  --control-plane-availability-policy SingleReplica \
  --arch s390x \
  --memory 32Gi \
  --cores 8 \
  --root-volume-size 100 \
  --infra-namespace=ext-infra-vms-ns \
  --infra-kubeconfig-file="${SHARED_DIR}/infra-kubeconfig" \
  --vm-node-selector role=kubevirt \
  --release-image ${OCP_IMAGE_MULTI} \
  --render-sensitive --render > /tmp/hc-manifests/kubevirt-hc.yaml
  #--release-image quay.io/openshift-release-dev/ocp-release:4.22.9-multi

echo "$(date) Rendered manifests to /tmp/hc-manifests/kubevirt-hc.yaml"
cat /tmp/hc-manifests/kubevirt-hc.yaml

# Patch the APIServer servicePublishingStrategy from LoadBalancer → NodePort
# with the LPAR host IP so VMIs get the correct address baked into ignition.
# The rendered manifest contains the HostedCluster object with spec.services[].
# We use Python (available in dev-scripts image) to do an in-place YAML edit.
python3 - <<PYEOF
import yaml, sys

with open('/tmp/hc-manifests/kubevirt-hc.yaml', 'r') as f:
    docs = list(yaml.safe_load_all(f))

mgmt_host_ip = "${MGMT_HOST_IP}"
patched = False
for doc in docs:
    if doc and doc.get('kind') == 'HostedCluster':
        for svc in doc.get('spec', {}).get('services', []):
            if svc.get('service') == 'APIServer':
                svc['servicePublishingStrategy'] = {
                    'type': 'NodePort',
                    'nodePort': {'address': mgmt_host_ip}
                }
                patched = True
                print(f"Patched APIServer → NodePort address={mgmt_host_ip}", file=sys.stderr)
                break

if not patched:
    print("WARNING: APIServer entry not found in spec.services — applying unpatched", file=sys.stderr)

# Filter out None docs — yaml.safe_load_all produces a None entry for
# the trailing '--- null' / empty document separator at end of file.
docs = [d for d in docs if d is not None]

with open('/tmp/hc-manifests/kubevirt-hc.yaml', 'w') as f:
    yaml.dump_all(docs, f, default_flow_style=False)
PYEOF

echo "$(date) Patched manifest:"
cat /tmp/hc-manifests/kubevirt-hc.yaml

echo "$(date) Applying patched HostedCluster manifests"
oc apply -f /tmp/hc-manifests/kubevirt-hc.yaml

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

oc wait --timeout=45m --for=condition=Available --namespace=hcpvirt-oz-ci-ns hostedclusters.hypershift.openshift.io/hcpvirt-oz-ci
echo "$(date) Kubevirt cluster is available"

# --- Step 3: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"

# Save mgmt kubeconfig so hypershift-conformance chain picks it up via mgmt_kubeconfig
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

# --- Step 4: Wait for the single worker node to join ---
echo "$(date) Waiting for 1 worker node to join the guest cluster"

VIRT_KC="${SHARED_DIR}/nested_kubeconfig"
REQUIRED_NODES=1
MAX_RETRIES=30
LPAR_IP=10.0.1.15

# --- Wait for kube-apiserver NodePort ---
NODEPORT=$(oc get svc kube-apiserver -n "${HC_NS}-${HC_NAME}" \
    -o jsonpath="{.spec.ports[?(@.port==6443)].nodePort}" 2>/dev/null || true)
echo "Kube-apiserver NodePort: $NODEPORT"

# --- Update kubeconfig server URL safely ---
CLSTR_NAME=$(oc --kubeconfig "$VIRT_KC" config view -o jsonpath='{.clusters[0].name}')
oc --kubeconfig "$VIRT_KC" config set-cluster "$CLSTR_NAME" \
  --server="https://${LPAR_IP}:${NODEPORT}"
echo "Updated kubeconfig server URL to https://${LPAR_IP}:${NODEPORT}"

# Restart MetalLB speaker daemonset on SNO once bfr starting the wait loop to trigger ARP announcements
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
      | grep -v "NotReady" | grep -c " Ready" || true)
    echo "$(date) Ready nodes: ${READY_NODES}/${REQUIRED_NODES}"
    if [[ ${READY_NODES} -ge ${REQUIRED_NODES} ]]; then
      echo "$(date) ${REQUIRED_NODES} nodes are Ready"
      return 0
    fi

    echo "$(date) Nodes not ready yet — printing debug status"
    echo "$(date) DEBUG: All nodes in guest cluster:"
    oc get no --kubeconfig "${VIRT_KC}" -o wide 2>/dev/null || echo "  (kubeconfig not yet accessible)"
    echo "$(date) DEBUG: KubeVirt VMs on infra cluster:"
    export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
    oc get vmi -n ext-infra-vms-ns 2>/dev/null || true

    echo "$(date) Waiting 90s before retrying node check (attempt $((retries + 1))/${MAX_RETRIES})"
    sleep 90
    retries=$((retries + 1))
  done
  echo "$(date) ERROR: Timed out waiting for ${REQUIRED_NODES} nodes to be Ready"

  echo "$(date) --- Final debug dump ---"
  echo "$(date) Guest cluster nodes:"
  oc get no --kubeconfig "${VIRT_KC}" -o wide 2>/dev/null || true

  echo "$(date) Guest cluster node conditions:"
  oc get no --kubeconfig "${VIRT_KC}" -o json 2>/dev/null \
    | jq '.items[] | {name: .metadata.name, conditions: .status.conditions}' || true

  echo "$(date) VMIs on infra cluster:"
  export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
  oc get vmi -A -o wide || true

  echo "$(date) VMI describe (all):"
  oc describe vmi -A || true

  echo "$(date) NodePool status:"
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc get np -A || true
  oc describe np -n "${HC_NS}" || true

  echo "$(date) HCP control plane pods:"
  oc get po -n "${HC_NS}-${HC_NAME}" -o wide || true

  echo "$(date) capi-provider logs:"
  oc logs -n "${HC_NS}-${HC_NAME}" -l app=capi-provider --all-containers=true --tail=100 || true

  echo "$(date) HCP kube-apiserver service (confirm NodePort):"
  oc get svc kube-apiserver -n "${HC_NS}-${HC_NAME}" -o yaml || true

  echo "$(date) Recent events in control plane namespace:"
  oc get events -n "${HC_NS}-${HC_NAME}" --sort-by='.lastTimestamp' | tail -30 || true

  echo "$(date) HostedCluster conditions:"
  oc get hc "${HC_NAME}" -n "${HC_NS}" -o jsonpath='{.status.conditions}' | jq . || true

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

# --- Step 8: Wait for console ClusterOperator, then pin test-apps to router node(s) ---
echo "$(date) Waiting for console ClusterOperator to become Available"
CONSOLE_MAX_WAIT=1800
CONSOLE_INTERVAL=30
CONSOLE_ELAPSED=0
CONSOLE_AVAILABLE=""
while [[ ${CONSOLE_ELAPSED} -lt ${CONSOLE_MAX_WAIT} ]]; do
  CONSOLE_AVAILABLE=$(oc get co console --kubeconfig "${VIRT_KC}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  if [[ "${CONSOLE_AVAILABLE}" == "True" ]]; then
    echo "$(date) console ClusterOperator is Available"
    break
  fi
  echo "$(date) console not yet Available (${CONSOLE_ELAPSED}s elapsed), status='${CONSOLE_AVAILABLE}'"
  sleep ${CONSOLE_INTERVAL}
  CONSOLE_ELAPSED=$((CONSOLE_ELAPSED + CONSOLE_INTERVAL))
done
if [[ "${CONSOLE_AVAILABLE}" != "True" ]]; then
  echo "$(date) ERROR: console ClusterOperator did not become Available within ${CONSOLE_MAX_WAIT}s"
  oc get co console --kubeconfig "${VIRT_KC}" -o yaml || true
  exit 1
fi

# --- Step 9: LoadBalancer targeting router node(s) only ---
# router-nodeport-default uses externalTrafficPolicy=Local, so NodePort only works on
# nodes running router-default. Do not target all virt-launcher pods.
echo "$(date) Resolving router worker node IP(s) for test-apps LoadBalancer"
export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"

ROUTER_NODES=$(oc --kubeconfig "${VIRT_KC}" get pods -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)

ROUTER_NODE_IPS=""
for node in ${ROUTER_NODES}; do
  ip=$(oc --kubeconfig "${VIRT_KC}" get node "${node}" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "$(date) router-default on node ${node} -> ${ip}"
  ROUTER_NODE_IPS="${ROUTER_NODE_IPS} ${ip}"
done

if [[ -z "${ROUTER_NODE_IPS// }" ]]; then
  echo "$(date) ERROR: could not determine router node IP(s)"
  exit 1
fi

# Service without selector (manual endpoints)
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
  type: LoadBalancer
SVCEOF

# Build Endpoints YAML for each router node IP
ENDPOINT_ADDRESSES=""
for ip in ${ROUTER_NODE_IPS}; do
  ENDPOINT_ADDRESSES="${ENDPOINT_ADDRESSES}
  - ip: ${ip}"
done

oc apply -f - <<EOF
apiVersion: v1
kind: Endpoints
metadata:
  name: test-apps
  namespace: ext-infra-vms-ns
subsets:
- addresses:
${ENDPOINT_ADDRESSES}
  ports:
  - name: https-443
    port: ${HTTPS_PORT}
  - name: http-80
    port: ${HTTP_PORT}
EOF

# Remove auto-generated slices from any prior selector-based Service
oc delete endpointslice -n ext-infra-vms-ns -l kubernetes.io/service-name=test-apps --ignore-not-found

oc get svc,endpoints test-apps -n ext-infra-vms-ns -o wide

# --- Step 10: Wait for all ClusterOperators to be Available=True and Degraded=False ---
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
  oc get machines -A || true

  echo "$(date) DEBUG: Infra cluster state at CO failure"
  export KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
  oc get no || true
  oc get vmi -A || true
  oc describe vmi -A || true
  oc get machines -a || true

  exit 1
fi

echo "$(date) HCP virt - external infra cluster is fully operational"

# Set KUBECONFIG to guest cluster so subsequent steps (hypershift-conformance) target it
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
