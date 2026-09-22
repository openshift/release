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

# Required for KubeVirt baseDomainPassthrough: guest *.apps becomes a subdomain of the
# management cluster's *.apps domain and HyperShift wires ingress automatically.
# See https://hypershift.pages.dev/how-to/kubevirt/ingress-and-dns/
oc patch ingresscontroller -n openshift-ingress-operator default \
  --type=json \
    -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {"wildcardPolicy": "WildcardsAllowed"}}]'

set +x
# Extract the management cluster pull secret for use when provisioning the hosted cluster
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
cp /tmp/.dockerconfigjson /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# HostedCluster name must match what hypershift-conformance derives from PROW_JOB_ID
# (sha256sum|cut -c-20). Namespace is still keyed off the MetalLB pool so each
# libvirt-s390x-oz lease keeps HCs isolated from leftover CRs on the other lease.
POOL_RANGE=$(oc get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || true)
echo "$(date) MetalLB IPAddressPool range: ${POOL_RANGE}"

HC_NAME="$(printf '%s' "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
if [[ "${POOL_RANGE}" == 192.168.2.* ]]; then
  HC_NS=hcpvirt-oz-ci-ns
elif [[ "${POOL_RANGE}" == 192.168.3.* ]]; then
  HC_NS=hcpvirtnew-oz-ci-ns
else
  echo "$(date) ERROR: Unrecognised IPAddressPool range '${POOL_RANGE}', expected 192.168.2.x or 192.168.3.x"
  exit 1
fi

echo "$(date) Using HC_NAME=${HC_NAME}, HC_NS=${HC_NS}"
echo "${HC_NAME}" > "${SHARED_DIR}/cluster-name"

# Omit --base-domain so HyperShift enables baseDomainPassthrough and creates the
# management-cluster wildcard Route/Service/EndpointSlice for guest *.apps ingress.
hcp create cluster kubevirt \
  --name ${HC_NAME} \
  --node-pool-replicas 2 \
  --pull-secret "${PULL_SECRET_FILE}" \
  --namespace ${HC_NS} \
  --control-plane-availability-policy SingleReplica \
  --arch s390x \
  --memory 16Gi \
  --cores 4 \
  --root-volume-size 60 \
  --release-image ${OCP_IMAGE_MULTI} \
  --annotations "resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-scheduler.kube-scheduler=memory=512Mi,cpu=500m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-controller-manager.kube-controller-manager=memory=1Gi,cpu=1000m" \
  --annotations "resource-request-override.hypershift.openshift.io/konnectivity-agent.konnectivity-agent=memory=512Mi,cpu=500m" \
  --annotations "resource-request-override.hypershift.openshift.io/oauth-openshift.oauth-openshift=memory=256Mi,cpu=300m" \
  --annotations "resource-request-override.hypershift.openshift.io/ingress-operator.ingress-operator=memory=256Mi,cpu=300m" \
  --annotations "resource-request-override.hypershift.openshift.io/openshift-apiserver.openshift-apiserver=memory=512Mi,cpu=300m"

oc wait --timeout=45m --for=condition=Available --namespace="${HC_NS}" "hostedclusters.hypershift.openshift.io/${HC_NAME}"
echo "$(date) Kubevirt cluster is available"

# --- Step 2: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"

# Persist management cluster kubeconfig separately so conformance steps can reference it
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

VIRT_KC="${SHARED_DIR}/nested_kubeconfig"
REQUIRED_NODES=2
MAX_RETRIES=30
API_MAX_WAIT=7200
API_INTERVAL=30
HCP_NS="${HC_NS}-${HC_NAME}"

CLSTR_NAME=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].name}')
ORIG_SERVER=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].cluster.server}')
echo "$(date) Original nested_kubeconfig server: ${ORIG_SERVER}"

# Cert SANs will not match LB/node IPs; skip TLS verify for all candidate endpoints.
oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" --insecure-skip-tls-verify=true

# --- Discover reachable guest API endpoints ---
# Do NOT hardcode LPAR IP:NodePort (e.g. 10.0.1.15:30417). That path is not
# DNAT'd from CI and fails with empty /readyz + TLS handshake timeout even when
# the HostedCluster/NodePool are healthy. Prefer:
#   1) original hcp Route/URL (CI already reaches *.apps on the mgmt cluster)
#   2) MetalLB LoadBalancer VIP on the kube-apiserver Service (:6443)
#   3) a management-node InternalIP + NodePort as last resort
echo "$(date) Discovering kube-apiserver Service endpoints..."
# Restart MetalLB speakers once so any VIP is announced before we probe.
echo "$(date) Restarting MetalLB speaker daemonset on management cluster once..."
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc get pods -n metallb-system 2>/dev/null || true
oc rollout restart daemonset speaker -n metallb-system || true
oc rollout status daemonset speaker -n metallb-system --timeout=120s || true

probe_readyz() {
  local url="$1"
  curl -sk --connect-timeout 10 --max-time 30 "${url%/}/readyz" 2>/dev/null || true
}

# Build / refresh candidate list each poll so a late MetalLB VIP can still be used.
build_api_candidates() {
  local nodeport=""
  local lb_ip=""
  local node_ip=""

  nodeport=$(oc get svc kube-apiserver -n "${HCP_NS}" \
    -o jsonpath="{.spec.ports[?(@.port==6443)].nodePort}" 2>/dev/null || true)
  lb_ip=$(oc get svc kube-apiserver -n "${HCP_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)

  API_CANDIDATES=()
  if [[ -n "${ORIG_SERVER}" ]]; then
    API_CANDIDATES+=("${ORIG_SERVER}")
  fi
  if [[ -n "${lb_ip}" ]]; then
    API_CANDIDATES+=("https://${lb_ip}:6443")
  fi
  if [[ -n "${node_ip}" && -n "${nodeport}" ]]; then
    API_CANDIDATES+=("https://${node_ip}:${nodeport}")
  fi

  echo "$(date) Candidates (nodePort=${nodeport:-none} lb=${lb_ip:-none} nodeIP=${node_ip:-none}): ${API_CANDIDATES[*]:-none}"
}

select_reachable_api() {
  local elapsed=0
  local readyz=""
  local candidate=""

  while [[ ${elapsed} -lt ${API_MAX_WAIT} ]]; do
    build_api_candidates
    if [[ ${#API_CANDIDATES[@]} -eq 0 ]]; then
      echo "$(date) No guest API candidates yet; waiting..."
    else
      for candidate in "${API_CANDIDATES[@]}"; do
        readyz=$(probe_readyz "${candidate}")
        echo "$(date) API wait (${elapsed}s): ${candidate} /readyz=${readyz:-<empty>}"
        if [[ "${readyz}" == "ok" ]]; then
          echo "$(date) Selecting reachable guest API endpoint: ${candidate}"
          oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
            --server="${candidate}" \
            --insecure-skip-tls-verify=true
          echo "$(date) Patched nested_kubeconfig server → ${candidate}"
          return 0
        fi
      done
    fi
    sleep ${API_INTERVAL}
    elapsed=$((elapsed + API_INTERVAL))
  done

  echo "$(date) ERROR: No guest API endpoint returned /readyz=ok within ${API_MAX_WAIT}s"
  echo "$(date) DEBUG: kube-apiserver Service:"
  oc get svc kube-apiserver -n "${HCP_NS}" -o yaml || true
  echo "$(date) DEBUG: nested_kubeconfig clusters:"
  oc --kubeconfig "${VIRT_KC}" config view || true
  return 1
}

echo "$(date) Nodepool status........"
oc get np -A || true
oc describe np -A || true

wait_for_nodes() {
  local retries=0
  local READY_NODES=0

  while [[ ${retries} -lt ${MAX_RETRIES} ]]; do
    READY_NODES=$(oc get no --kubeconfig "${VIRT_KC}" --request-timeout=30s --no-headers 2>/dev/null \
      | grep -c " Ready" || true)
    echo "$(date) Ready nodes: ${READY_NODES}/${REQUIRED_NODES} (attempt $((retries + 1))/${MAX_RETRIES})"
    if [[ ${READY_NODES} -ge ${REQUIRED_NODES} ]]; then
      echo "$(date) ${REQUIRED_NODES} nodes are Ready"
      oc get no --kubeconfig "${VIRT_KC}" -o wide || true
      return 0
    fi

    echo "$(date) Nodes not ready yet — printing debug status"
    oc get no --kubeconfig "${VIRT_KC}" -o wide --request-timeout=30s 2>/dev/null || true
    oc get vmi -n "${HCP_NS}" 2>/dev/null || true

    sleep 60
    retries=$((retries + 1))
  done

  echo "$(date) ERROR: Timed out waiting for ${REQUIRED_NODES} nodes to be Ready after ${MAX_RETRIES} retries"
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc get no || true
  oc get hc -A || true
  oc describe hc -n "${HC_NS}" "${HC_NAME}" || true
  oc get np -A || true
  oc describe np -n "${HC_NS}" || true
  oc get po -n "${HCP_NS}" || true
  oc get vmi -A || true
  oc describe vmi -A || true
  return 1
}

select_reachable_api
wait_for_nodes

# --- Step 4: Wait for HyperShift baseDomainPassthrough ingress wiring on mgmt cluster ---
# With baseDomainPassthrough, HyperShift creates a wildcard passthrough Route, a
# selector-less Service, and EndpointSlices targeting guest VM machineNetwork IPs.
echo "$(date) Waiting for baseDomainPassthrough ingress resources in ${HCP_NS}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

PASSTHROUGH_WAIT=900  # 15 minutes
PASSTHROUGH_INTERVAL=15
PASSTHROUGH_ELAPSED=0
PASSTHROUGH_READY=false

while [[ ${PASSTHROUGH_ELAPSED} -lt ${PASSTHROUGH_WAIT} ]]; do
  PASSTHROUGH_ROUTE=$(oc get route -n "${HCP_NS}" -o name 2>/dev/null | grep default-ingress-passthrough-route || true)
  PASSTHROUGH_SVC=$(oc get svc -n "${HCP_NS}" -o name 2>/dev/null | grep default-ingress-passthrough-service || true)
  PASSTHROUGH_EPS=$(oc get endpointslice -n "${HCP_NS}" -o name 2>/dev/null | grep default-ingress-passthrough-service || true)

  if [[ -n "${PASSTHROUGH_ROUTE}" && -n "${PASSTHROUGH_SVC}" && -n "${PASSTHROUGH_EPS}" ]]; then
    echo "$(date) baseDomainPassthrough ingress resources are present:"
    echo "  ${PASSTHROUGH_ROUTE}"
    echo "  ${PASSTHROUGH_SVC}"
    echo "  ${PASSTHROUGH_EPS}"
    PASSTHROUGH_READY=true
    break
  fi

  echo "$(date) baseDomainPassthrough ingress not ready yet (${PASSTHROUGH_ELAPSED}s elapsed)"
  oc get route,svc,endpointslice -n "${HCP_NS}" 2>/dev/null || true
  sleep ${PASSTHROUGH_INTERVAL}
  PASSTHROUGH_ELAPSED=$((PASSTHROUGH_ELAPSED + PASSTHROUGH_INTERVAL))
done

if [[ "${PASSTHROUGH_READY}" != "true" ]]; then
  echo "$(date) ERROR: baseDomainPassthrough ingress resources did not appear in ${HCP_NS}"
  oc get route,svc,endpointslice -n "${HCP_NS}" -o wide || true
  exit 1
fi

# --- Step 5: Wait for all guest cluster ClusterOperators to be Available ---
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
  oc get co --kubeconfig "${VIRT_KC}" || true
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
  oc describe hc -n "${HC_NS}" "${HC_NAME}" || true
  oc get np -A || true
  oc describe np -n "${HC_NS}" || true
  oc get po -n "${HCP_NS}" || true
  oc get vmi -A || true
  oc describe vmi -A || true

  exit 1
fi

echo "$(date) HCP KubeVirt hosted cluster is fully operational"

# Print control-plane workload resource requests regardless of pass/fail
echo "$(date) Control-plane deploy/statefulset resource requests:"
oc get deploy,statefulset -n "${HCP_NS}" \
  --kubeconfig="${SHARED_DIR}/kubeconfig" \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEM:.spec.template.spec.containers[0].resources.requests.memory' || true

# --- Step 6: Switch KUBECONFIG to the guest cluster for downstream conformance steps ---
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
