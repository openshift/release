#!/bin/bash
#
# Create a KubeVirt HostedCluster on the IBM Z OZ libvirt management cluster.
#
# RCA notes (learned from PR #84152 rehearsals):
# - HostedCluster/NodePool can be healthy while CI cannot reach the guest API.
# - LPAR IP:NodePort (default 10.0.1.15:<np>) is flaky: sometimes /readyz=ok,
#   sometimes empty response + TLS handshake timeout.
# - Prefer stable endpoints (hcp Route, MetalLB VIP, node InternalIP) and only
#   fall back to LPAR last.
# - Omit --base-domain so HyperShift enables baseDomainPassthrough for *.apps;
#   custom base-domain + manual test-apps LB caused ingress-canary timeouts.
#
set -x
set -e

dump_mgmt_debug() {
  echo "$(date) ===== DEBUG: management cluster snapshot ====="
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc get no -o wide || true
  oc get hc -A -o wide || true
  oc describe hc -n "${HC_NS}" "${HC_NAME}" || true
  oc get np -A -o wide || true
  oc describe np -n "${HC_NS}" || true
  oc get svc -n "${HCP_NS}" -o wide || true
  oc get po -n "${HCP_NS}" -o wide || true
  oc get vmi -A -o wide || true
  oc get route,endpointslice -n "${HCP_NS}" -o wide || true
  echo "$(date) ===== END management cluster snapshot ====="
}

dump_guest_debug() {
  echo "$(date) ===== DEBUG: guest cluster snapshot (via ${VIRT_KC}) ====="
  echo "$(date) nested_kubeconfig contents (redacted secrets):"
  oc --kubeconfig "${VIRT_KC}" config view || true
  oc get no --kubeconfig "${VIRT_KC}" -o wide --request-timeout=30s || true
  oc get co --kubeconfig "${VIRT_KC}" || true
  oc get pods -A --kubeconfig "${VIRT_KC}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
  echo "$(date) ===== END guest cluster snapshot ====="
}

# --- Step 0: Download and install the hcp CLI ---
echo "$(date) Installing hcp CLI"
mkdir -p /tmp/hcp_cli
downloadURL=$(oc get ConsoleCLIDownload hcp-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
echo "$(date) hcp CLI download URL: ${downloadURL}"
curl -k --output /tmp/hcp.tar.gz "${downloadURL}"
tar -xvf /tmp/hcp.tar.gz -C /tmp/hcp_cli
chmod +x /tmp/hcp_cli/hcp
export PATH=$PATH:/tmp/hcp_cli
hcp version

# --- Step 1: Prepare management cluster and create the HCP KubeVirt hosted cluster ---
echo "$(date) Targeting management cluster kubeconfig: ${SHARED_DIR}/kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
echo "$(date) Management API server: $(oc whoami --show-server 2>/dev/null || echo unknown)"
echo "$(date) Management nodes:"
oc get no -o wide || true

# Required for KubeVirt baseDomainPassthrough: guest *.apps becomes a subdomain of the
# management cluster's *.apps domain and HyperShift wires ingress automatically.
# See https://hypershift.pages.dev/how-to/kubevirt/ingress-and-dns/
echo "$(date) Enabling wildcard routeAdmission on default ingresscontroller"
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
echo "$(date) MetalLB IPAddressPool range: ${POOL_RANGE:-<empty>}"
oc get ipaddresspool -n metallb-system -o yaml || true

HC_NAME="$(printf '%s' "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
if [[ "${POOL_RANGE}" == 192.168.2.* ]]; then
  HC_NS=hcpvirt-oz-ci-ns
elif [[ "${POOL_RANGE}" == 192.168.3.* ]]; then
  HC_NS=hcpvirtnew-oz-ci-ns
else
  echo "$(date) ERROR: Unrecognised IPAddressPool range '${POOL_RANGE}', expected 192.168.2.x or 192.168.3.x"
  exit 1
fi

echo "$(date) Using HC_NAME=${HC_NAME} (PROW_JOB_ID hash for hypershift-conformance)"
echo "$(date) Using HC_NS=${HC_NS} (lease-specific namespace)"
echo "${HC_NAME}" > "${SHARED_DIR}/cluster-name"
echo "$(date) Wrote ${SHARED_DIR}/cluster-name"

# Omit --base-domain so HyperShift enables baseDomainPassthrough and creates the
# management-cluster wildcard Route/Service/EndpointSlice for guest *.apps ingress.
echo "$(date) Creating KubeVirt HostedCluster (baseDomainPassthrough; no --base-domain)"
hcp create cluster kubevirt \
  --name "${HC_NAME}" \
  --node-pool-replicas 2 \
  --pull-secret "${PULL_SECRET_FILE}" \
  --namespace "${HC_NS}" \
  --control-plane-availability-policy SingleReplica \
  --arch s390x \
  --memory 16Gi \
  --cores 4 \
  --root-volume-size 60 \
  --release-image "${OCP_IMAGE_MULTI}" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-scheduler.kube-scheduler=memory=512Mi,cpu=500m" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-controller-manager.kube-controller-manager=memory=1Gi,cpu=1000m" \
  --annotations "resource-request-override.hypershift.openshift.io/konnectivity-agent.konnectivity-agent=memory=512Mi,cpu=500m" \
  --annotations "resource-request-override.hypershift.openshift.io/oauth-openshift.oauth-openshift=memory=256Mi,cpu=300m" \
  --annotations "resource-request-override.hypershift.openshift.io/ingress-operator.ingress-operator=memory=256Mi,cpu=300m" \
  --annotations "resource-request-override.hypershift.openshift.io/openshift-apiserver.openshift-apiserver=memory=512Mi,cpu=300m"

echo "$(date) Waiting up to 45m for HostedCluster/${HC_NAME} Available"
oc wait --timeout=45m --for=condition=Available --namespace="${HC_NS}" "hostedclusters.hypershift.openshift.io/${HC_NAME}"
echo "$(date) HostedCluster is Available"
oc get hc -n "${HC_NS}" "${HC_NAME}" -o yaml | grep -E 'type:|status:|reason:|message:' | head -80 || true

# --- Step 2: Retrieve the guest cluster kubeconfig ---
echo "$(date) Retrieving guest cluster kubeconfig via hcp create kubeconfig"
hcp create kubeconfig kubevirt --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"
# Downstream steps (hypershift-conformance) read SHARED_DIR/nested_kubeconfig directly.
# Do not rely on exporting KUBECONFIG — each ci-operator step is a new process.
echo "${SHARED_DIR}/nested_kubeconfig" > "${SHARED_DIR}/nested_kubeconfig.path"
echo "$(date) Wrote guest kubeconfig to ${SHARED_DIR}/nested_kubeconfig (path marker: nested_kubeconfig.path)"

# Persist management cluster kubeconfig separately so conformance can look up HC metadata
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"
echo "$(date) Wrote ${SHARED_DIR}/mgmt_kubeconfig"

VIRT_KC="${SHARED_DIR}/nested_kubeconfig"
REQUIRED_NODES=2
MAX_RETRIES=30
API_MAX_WAIT=7200
API_INTERVAL=30
HCP_NS="${HC_NS}-${HC_NAME}"

CLSTR_NAME=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].name}')
ORIG_SERVER=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].cluster.server}')
# Hostname from the original server URL — used as --tls-server-name when we rewrite
# the server to an IP so the kube-apiserver cert still validates (when SANs match).
ORIG_TLS_SERVER_NAME=$(printf '%s' "${ORIG_SERVER}" | sed -E 's#^https://([^:/]+).*#\1#')
echo "$(date) Original nested_kubeconfig cluster=${CLSTR_NAME} server=${ORIG_SERVER}"
echo "$(date) Derived TLS server name for cert verification: ${ORIG_TLS_SERVER_NAME}"
oc --kubeconfig "${VIRT_KC}" config view || true

patch_guest_server() {
  local server="$1"
  # Prefer tls-server-name (original Route/API hostname) over blanket insecure skip.
  # Fall back to insecure-skip when the original server had no usable hostname
  # (e.g. already an IP) — IP endpoints never match the apiserver cert SAN.
  if [[ -n "${ORIG_TLS_SERVER_NAME}" && "${ORIG_TLS_SERVER_NAME}" != "${ORIG_SERVER}" && "${ORIG_TLS_SERVER_NAME}" =~ [a-zA-Z] ]]; then
    echo "$(date) Patching guest server → ${server} (tls-server-name=${ORIG_TLS_SERVER_NAME})"
    oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
      --server="${server}" \
      --tls-server-name="${ORIG_TLS_SERVER_NAME}" \
      --insecure-skip-tls-verify=false
  else
    echo "$(date) Patching guest server → ${server} (insecure-skip-tls-verify; no usable ORIG hostname)"
    oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
      --server="${server}" \
      --insecure-skip-tls-verify=true
  fi
}

# --- Discover reachable guest API endpoints ---
LPAR_HOST_IP="${LPAR_HOST_IP:-10.0.1.15}"
echo "$(date) Discovering kube-apiserver endpoints (LPAR fallback=${LPAR_HOST_IP})"
echo "$(date) Preference order: hcp original URL → MetalLB VIP:6443 → nodeIP:NodePort → LPAR:NodePort"

echo "$(date) Restarting MetalLB speaker daemonset once to refresh VIP ARP announcements"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc get pods -n metallb-system -o wide 2>/dev/null || true
oc rollout restart daemonset speaker -n metallb-system || true
oc rollout status daemonset speaker -n metallb-system --timeout=120s || true

probe_readyz() {
  local url="$1"
  # -k: probe must work even before kubeconfig TLS knobs are settled
  curl -sk --connect-timeout 10 --max-time 30 "${url%/}/readyz" 2>/dev/null || true
}

# Build / refresh candidate list each poll so a late MetalLB VIP can still be used.
# Order matters: first /readyz=ok wins, so put the most stable endpoints first.
build_api_candidates() {
  local nodeport=""
  local lb_ip=""
  local node_ip=""
  local svc_type=""

  nodeport=$(oc get svc kube-apiserver -n "${HCP_NS}" \
    -o jsonpath="{.spec.ports[?(@.port==6443)].nodePort}" 2>/dev/null || true)
  lb_ip=$(oc get svc kube-apiserver -n "${HCP_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  svc_type=$(oc get svc kube-apiserver -n "${HCP_NS}" -o jsonpath='{.spec.type}' 2>/dev/null || true)
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
  if [[ -n "${LPAR_HOST_IP}" && -n "${nodeport}" ]]; then
    API_CANDIDATES+=("https://${LPAR_HOST_IP}:${nodeport}")
  fi

  echo "$(date) Candidates type=${svc_type:-?} nodePort=${nodeport:-none} lb=${lb_ip:-none} nodeIP=${node_ip:-none} lpar=${LPAR_HOST_IP}"
  local i=0
  for c in "${API_CANDIDATES[@]:-}"; do
    echo "$(date)   [$i] ${c}"
    i=$((i + 1))
  done
}

select_reachable_api() {
  local elapsed=0
  local readyz=""
  local candidate=""
  local selected=""

  while [[ ${elapsed} -lt ${API_MAX_WAIT} ]]; do
    build_api_candidates
    if [[ ${#API_CANDIDATES[@]} -eq 0 ]]; then
      echo "$(date) No guest API candidates yet; waiting (${elapsed}s/${API_MAX_WAIT}s)..."
      oc get svc -n "${HCP_NS}" -o wide || true
    else
      for candidate in "${API_CANDIDATES[@]}"; do
        readyz=$(probe_readyz "${candidate}")
        echo "$(date) API wait (${elapsed}s/${API_MAX_WAIT}s): ${candidate} /readyz=${readyz:-<empty>}"
        if [[ "${readyz}" == "ok" ]]; then
          selected="${candidate}"
          break
        fi
      done
      if [[ -n "${selected}" ]]; then
        echo "$(date) SUCCESS: reachable guest API endpoint selected: ${selected}"
        patch_guest_server "${selected}"
        echo "$(date) Post-patch nested_kubeconfig:"
        oc --kubeconfig "${VIRT_KC}" config view || true
        # Confirm oc can talk to the guest with the patched kubeconfig
        if oc --kubeconfig "${VIRT_KC}" --request-timeout=30s get --raw=/readyz 2>/dev/null | grep -q '^ok$'; then
          echo "$(date) oc --kubeconfig nested_kubeconfig get --raw=/readyz => ok"
          return 0
        fi
        echo "$(date) WARNING: /readyz via curl was ok but oc get --raw=/readyz failed; dumping and continuing to retry"
        dump_guest_debug
        selected=""
      fi
    fi
    sleep ${API_INTERVAL}
    elapsed=$((elapsed + API_INTERVAL))
  done

  echo "$(date) ERROR: No guest API endpoint returned /readyz=ok within ${API_MAX_WAIT}s"
  echo "$(date) DEBUG: kube-apiserver Service YAML:"
  oc get svc kube-apiserver -n "${HCP_NS}" -o yaml || true
  dump_mgmt_debug
  dump_guest_debug
  return 1
}

echo "$(date) NodePool status before API/node waits:"
oc get np -A -o wide || true
oc describe np -A || true

wait_for_nodes() {
  local retries=0
  local READY_NODES=0
  local oc_rc=0

  while [[ ${retries} -lt ${MAX_RETRIES} ]]; do
    set +e
    NODE_OUT=$(oc get no --kubeconfig "${VIRT_KC}" --request-timeout=30s --no-headers 2>/tmp/guest-nodes.err)
    oc_rc=$?
    set -e
    if [[ ${oc_rc} -ne 0 ]]; then
      echo "$(date) oc get nodes failed (rc=${oc_rc}) attempt $((retries + 1))/${MAX_RETRIES}:"
      cat /tmp/guest-nodes.err || true
      READY_NODES=0
    else
      READY_NODES=$(printf '%s\n' "${NODE_OUT}" | grep -c " Ready" || true)
      echo "$(date) Ready nodes: ${READY_NODES}/${REQUIRED_NODES} (attempt $((retries + 1))/${MAX_RETRIES})"
      printf '%s\n' "${NODE_OUT}"
    fi

    if [[ ${READY_NODES} -ge ${REQUIRED_NODES} ]]; then
      echo "$(date) ${REQUIRED_NODES} nodes are Ready"
      oc get no --kubeconfig "${VIRT_KC}" -o wide || true
      return 0
    fi

    echo "$(date) Nodes not ready yet — printing debug status"
    oc get no --kubeconfig "${VIRT_KC}" -o wide --request-timeout=30s 2>/dev/null || true
    oc get vmi -n "${HCP_NS}" -o wide 2>/dev/null || true
    oc get po -n "${HCP_NS}" -l kubevirt.io=virt-launcher -o wide 2>/dev/null || true

    sleep 60
    retries=$((retries + 1))
  done

  echo "$(date) ERROR: Timed out waiting for ${REQUIRED_NODES} nodes to be Ready after ${MAX_RETRIES} retries"
  dump_mgmt_debug
  dump_guest_debug
  return 1
}

select_reachable_api
wait_for_nodes

# --- Step 4: Wait for HyperShift baseDomainPassthrough ingress wiring on mgmt cluster ---
echo "$(date) Waiting for baseDomainPassthrough ingress resources in ${HCP_NS}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

PASSTHROUGH_WAIT=900
PASSTHROUGH_INTERVAL=15
PASSTHROUGH_ELAPSED=0
PASSTHROUGH_READY=false

while [[ ${PASSTHROUGH_ELAPSED} -lt ${PASSTHROUGH_WAIT} ]]; do
  PASSTHROUGH_ROUTE=$(oc get route -n "${HCP_NS}" -o name 2>/dev/null | grep default-ingress-passthrough-route || true)
  PASSTHROUGH_SVC=$(oc get svc -n "${HCP_NS}" -o name 2>/dev/null | grep default-ingress-passthrough-service || true)
  PASSTHROUGH_EPS=$(oc get endpointslice -n "${HCP_NS}" -o name 2>/dev/null | grep default-ingress-passthrough-service || true)

  echo "$(date) passthrough check (${PASSTHROUGH_ELAPSED}s): route=${PASSTHROUGH_ROUTE:-none} svc=${PASSTHROUGH_SVC:-none} eps=${PASSTHROUGH_EPS:-none}"

  if [[ -n "${PASSTHROUGH_ROUTE}" && -n "${PASSTHROUGH_SVC}" && -n "${PASSTHROUGH_EPS}" ]]; then
    echo "$(date) baseDomainPassthrough ingress resources are present"
    oc get route,svc,endpointslice -n "${HCP_NS}" -o wide || true
    PASSTHROUGH_READY=true
    break
  fi

  oc get route,svc,endpointslice -n "${HCP_NS}" 2>/dev/null || true
  sleep ${PASSTHROUGH_INTERVAL}
  PASSTHROUGH_ELAPSED=$((PASSTHROUGH_ELAPSED + PASSTHROUGH_INTERVAL))
done

if [[ "${PASSTHROUGH_READY}" != "true" ]]; then
  echo "$(date) ERROR: baseDomainPassthrough ingress resources did not appear in ${HCP_NS}"
  dump_mgmt_debug
  exit 1
fi

# --- Step 5: Wait for all guest cluster ClusterOperators to be Available ---
echo "$(date) Waiting for all ClusterOperators to be Available (and not Degraded)"
CO_MAX_WAIT=1800
CO_INTERVAL=30
CO_ELAPSED=0
CO_HEALTHY=false

while [[ ${CO_ELAPSED} -lt ${CO_MAX_WAIT} ]]; do
  set +e
  CO_OUT=$(oc get co --kubeconfig "${VIRT_KC}" --no-headers 2>/tmp/guest-co.err)
  CO_RC=$?
  set -e

  if [[ ${CO_RC} -ne 0 ]]; then
    echo "$(date) oc get co failed (rc=${CO_RC}) at ${CO_ELAPSED}s:"
    cat /tmp/guest-co.err || true
  elif [[ -z "${CO_OUT}" ]]; then
    echo "$(date) oc get co returned no rows at ${CO_ELAPSED}s — not treating as healthy"
  else
    # $3=AVAILABLE $4=PROGRESSING $5=DEGRADED
    NOT_AVAILABLE=$(printf '%s\n' "${CO_OUT}" | awk '$3 != "True" {print $1" available="$3" progressing="$4" degraded="$5}')
    DEGRADED=$(printf '%s\n' "${CO_OUT}" | awk '$5 == "True" {print $1" degraded=True"}')
    if [[ -z "${NOT_AVAILABLE}" && -z "${DEGRADED}" ]]; then
      echo "$(date) All ClusterOperators are Available=True and Degraded=False"
      printf '%s\n' "${CO_OUT}"
      CO_HEALTHY=true
      break
    fi
    echo "$(date) ClusterOperators not yet healthy (${CO_ELAPSED}s elapsed)"
    [[ -n "${NOT_AVAILABLE}" ]] && echo "$(date) not Available:" && echo "${NOT_AVAILABLE}"
    [[ -n "${DEGRADED}" ]] && echo "$(date) Degraded:" && echo "${DEGRADED}"
  fi

  sleep ${CO_INTERVAL}
  CO_ELAPSED=$((CO_ELAPSED + CO_INTERVAL))
done

if [[ "${CO_HEALTHY}" != "true" ]]; then
  echo "$(date) ERROR: ClusterOperators did not become healthy within ${CO_MAX_WAIT}s"
  dump_guest_debug
  dump_mgmt_debug
  exit 1
fi

echo "$(date) HCP KubeVirt hosted cluster is fully operational"
echo "$(date) Artifacts for downstream steps:"
echo "  nested_kubeconfig=${SHARED_DIR}/nested_kubeconfig"
echo "  mgmt_kubeconfig=${SHARED_DIR}/mgmt_kubeconfig"
echo "  cluster-name=$(cat "${SHARED_DIR}/cluster-name")"
echo "  guest API server=$(oc --kubeconfig "${VIRT_KC}" config view -o jsonpath='{.clusters[0].cluster.server}')"

echo "$(date) Control-plane deploy/statefulset resource requests:"
oc get deploy,statefulset -n "${HCP_NS}" \
  --kubeconfig="${SHARED_DIR}/kubeconfig" \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEM:.spec.template.spec.containers[0].resources.requests.memory' || true

echo "$(date) Create step complete — hypershift-conformance will load ${SHARED_DIR}/nested_kubeconfig"
