#!/bin/bash
#
# Create a KubeVirt HostedCluster on the IBM Z OZ libvirt management cluster.
#
# Stability model (learned from other-arch HCP jobs + OZ rehearsals):
# - AWS/Azure/Agent/Power expose guest API via DNS hostname (LB or Route).
# - KubeVirt defaults to MetalLB LoadBalancer without --external-dns-domain;
#   that VIP is L2-only on OZ and not CI-routable (same class as BM without
#   squid proxy-url).
# - KubeVirt supports APIServer=Route (hostname required). CI already reaches
#   management *.apps over VPN (hcp-cli-download, mgmt API). Publishing the
#   guest API on that same ingress path is the durable CI endpoint.
# - LPAR:NodePort remains a fallback (flaky across CI pods/VPN); MetalLB VIP /
#   nodeIP are RCA-only.
# - Downstream steps get a new CI pod + VPN; a hostname on mgmt ingress is far
#   more stable across steps than 10.0.1.15:NodePort.
# - Omit --base-domain so HyperShift enables baseDomainPassthrough for *.apps.
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
# Prefer TLS verification. ConsoleCLIDownload on some clusters serves a
# self-signed/service-CA cert; fall back to -k only if the verified fetch fails.
if ! curl -fsSL --connect-timeout 30 --max-time 300 --output /tmp/hcp.tar.gz "${downloadURL}"; then
  echo "$(date) WARNING: TLS-verified hcp download failed; retrying with curl -k (cluster service CA mismatch is common)"
  curl -fkSL --connect-timeout 30 --max-time 300 --output /tmp/hcp.tar.gz "${downloadURL}"
fi
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
echo -n "${HC_NS}" > "${SHARED_DIR}/cluster-namespace"
echo "$(date) Wrote ${SHARED_DIR}/cluster-name and ${SHARED_DIR}/cluster-namespace"

# Management *.apps domain is already CI-reachable over VPN (same path as hcp CLI
# download). Publish guest APIServer via Route on that domain — matches how other
# platforms give CI a DNS hostname instead of a private VIP/NodePort.
# See https://hypershift.pages.dev/reference/service-publishing-strategies/ (KubeVirt).
APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
if [[ -z "${APPS_DOMAIN}" ]]; then
  echo "$(date) ERROR: could not read ingresses.config.openshift.io/cluster .spec.domain"
  oc get ingresses.config.openshift.io cluster -o yaml || true
  exit 1
fi
API_ROUTE_HOSTNAME="api-${HC_NAME}.${APPS_DOMAIN}"
echo "$(date) Management apps domain: ${APPS_DOMAIN}"
echo "$(date) Guest API Route hostname: ${API_ROUTE_HOSTNAME}"

echo "$(date) Installing yq (render/patch HostedCluster services like Power/Agent HCP creates)"
mkdir -p /tmp/bin /tmp/hc-manifests
curl -fsSL -o /tmp/bin/yq https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_amd64
chmod +x /tmp/bin/yq
export PATH="/tmp/bin:${PATH}"

# Omit --base-domain so HyperShift enables baseDomainPassthrough for guest *.apps.
# Render + patch APIServer→Route before apply (publishing strategy is immutable).
echo "$(date) Rendering KubeVirt HostedCluster (baseDomainPassthrough; APIServer=Route)"
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
  --annotations "resource-request-override.hypershift.openshift.io/openshift-apiserver.openshift-apiserver=memory=512Mi,cpu=300m" \
  --render --render-sensitive > /tmp/hcpvirt-oz-render.yaml

echo "$(date) Splitting render and patching APIServer → Route/${API_ROUTE_HOSTNAME}"
# Power/Agent pattern: csplit multi-doc render, patch HostedCluster services, apply.
csplit -s -f /tmp/hc-manifests/manifest_ -b '%02d.yaml' /tmp/hcpvirt-oz-render.yaml '/^---$/' '{*}' || true
shopt -s nullglob
for file in /tmp/hc-manifests/manifest_*.yaml; do
  if grep -q 'kind: HostedCluster' "${file}"; then
    yq eval -i \
      "(.spec.services[] | select(.service == \"APIServer\") | .servicePublishingStrategy) = {\"type\": \"Route\", \"route\": {\"hostname\": \"${API_ROUTE_HOSTNAME}\"}}" \
      "${file}"
    echo "$(date) Patched ${file} services:"
    yq eval '.spec.services' "${file}" || true
  fi
done

echo "$(date) Applying rendered manifests"
for file in /tmp/hc-manifests/manifest_*.yaml; do
  [[ -s "${file}" ]] || continue
  oc apply -f "${file}"
done
shopt -u nullglob

echo "$(date) Waiting up to 45m for HostedCluster/${HC_NAME} Available"
oc wait --timeout=45m --for=condition=Available --namespace="${HC_NS}" "hostedclusters.hypershift.openshift.io/${HC_NAME}"
echo "$(date) HostedCluster is Available"
oc get hc -n "${HC_NS}" "${HC_NAME}" -o yaml | grep -E 'type:|status:|reason:|message:|controlPlaneEndpoint|hostname' | head -100 || true
echo "$(date) API-related Routes/Services in control-plane namespace ${HC_NS}-${HC_NAME}:"
oc get route,svc -n "${HC_NS}-${HC_NAME}" -o wide || true

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
# LPAR VPN flake either recovers in minutes or never (#84152). Cap wait so we
# fail with diagnostics instead of burning ~2h of empty probes.
API_MAX_WAIT=2400
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
  local host
  host=$(printf '%s' "${server}" | sed -E 's#^https://([^:/]+).*#\1#')
  # Prefer SNI matching the endpoint hostname (Route cert SAN). Fall back to the
  # original kubeconfig hostname, then insecure-skip for bare IPs (LPAR/VIP).
  if [[ -n "${host}" && "${host}" =~ [a-zA-Z] ]]; then
    echo "$(date) Patching guest server → ${server} (tls-server-name=${host})"
    oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
      --server="${server}" \
      --tls-server-name="${host}" \
      --insecure-skip-tls-verify=false
  elif [[ -n "${ORIG_TLS_SERVER_NAME}" && "${ORIG_TLS_SERVER_NAME}" =~ [a-zA-Z] ]]; then
    echo "$(date) Patching guest server → ${server} (tls-server-name=${ORIG_TLS_SERVER_NAME})"
    oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
      --server="${server}" \
      --tls-server-name="${ORIG_TLS_SERVER_NAME}" \
      --insecure-skip-tls-verify=false
  else
    echo "$(date) Patching guest server → ${server} (insecure-skip-tls-verify; IP-only endpoint)"
    oc --kubeconfig "${VIRT_KC}" config set-cluster "${CLSTR_NAME}" \
      --server="${server}" \
      --insecure-skip-tls-verify=true
  fi
}

# --- Discover reachable guest API endpoints ---
#
# Preference (CI-stable first), learned from other-arch HCP + OZ rehearsals:
# 1) Management ingress Route hostname — same *.apps path CI already uses
# 2) LPAR:NodePort — historical VPN path (flaky across pods)
# 3) nodeIP:NodePort / MetalLB VIP — on-bridge only; RCA
#
LPAR_HOST_IP="${LPAR_HOST_IP:-10.0.1.15}"
echo "$(date) Discovering kube-apiserver endpoints (LPAR=${LPAR_HOST_IP} route=${API_ROUTE_HOSTNAME})"
echo "$(date) Preference order: mgmt Route → LPAR:NodePort → nodeIP:NodePort → MetalLB VIP → hcp original"

echo "$(date) Restarting MetalLB speaker daemonset once (guest ingress / residual LB services)"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc get pods -n metallb-system -o wide 2>/dev/null || true
oc rollout restart daemonset speaker -n metallb-system || true
oc rollout status daemonset speaker -n metallb-system --timeout=120s || true

dump_ci_to_lpar_path() {
  # Record CI→LPAR path details for VPN/MTU/routing RCA (best-effort).
  echo "$(date) ===== CI→LPAR path diagnostics ====="
  echo "$(date) hostname=$(hostname -f 2>/dev/null || hostname)"
  [[ -e /tmp/vpn/up ]] && echo "$(date) VPN marker /tmp/vpn/up present" || echo "$(date) VPN marker /tmp/vpn/up MISSING"
  ip route get "${LPAR_HOST_IP}" 2>/dev/null || true
  ip -o link show 2>/dev/null | head -30 || true
  echo "$(date) ===== END CI→LPAR path diagnostics ====="
}

# Confirm guest API health via mgmt kube-apiserver tunnel (works from CI even when
# the MetalLB VIP is not routed to the build farm). Uses no extra images (s390x-safe).
probe_readyz_via_portforward() {
  local ns="$1"
  local local_port="${2:-16443}"
  echo "$(date) Port-forward probe: svc/kube-apiserver in ${ns} → 127.0.0.1:${local_port}"
  oc port-forward -n "${ns}" svc/kube-apiserver "${local_port}:6443" >/tmp/hcpvirt-oz-pf.log 2>&1 &
  local pf_pid=$!
  local out=""
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if ! kill -0 "${pf_pid}" 2>/dev/null; then
      echo "$(date) port-forward exited early; log:"
      cat /tmp/hcpvirt-oz-pf.log || true
      break
    fi
    out=$(curl -sk --connect-timeout 2 --max-time 5 "https://127.0.0.1:${local_port}/readyz" 2>/dev/null || true)
    if [[ -n "${out}" ]]; then
      break
    fi
  done
  kill "${pf_pid}" 2>/dev/null || true
  wait "${pf_pid}" 2>/dev/null || true
  echo "$(date) Port-forward /readyz=${out:-<empty>}"
  [[ "${out}" == "ok" ]]
}

probe_readyz() {
  local url="$1"
  local body=""
  local http_code="000"
  local rc=0
  # Short timeouts: unreachable private VIPs must fail fast so LPAR is tried soon.
  # Log curl_rc/http_code on stderr so empty bodies are distinguishable (timeout vs refuse).
  set +e
  body=$(curl -sk --connect-timeout 5 --max-time 10 -w '\n%{http_code}' "${url%/}/readyz" 2>/tmp/hcpvirt-oz-probe.err)
  rc=$?
  set -e
  http_code=$(printf '%s\n' "${body}" | tail -n1)
  body=$(printf '%s\n' "${body}" | sed '$d')
  echo "$(date) probe ${url} curl_rc=${rc} http=${http_code} body=${body:-<empty>}" >&2
  if [[ ${rc} -ne 0 ]]; then
    cat /tmp/hcpvirt-oz-probe.err >&2 || true
  fi
  printf '%s' "${body}"
}

# Append URL if non-empty and not already present.
add_candidate() {
  local url="$1"
  [[ -z "${url}" ]] && return 0
  local existing
  for existing in "${API_CANDIDATES[@]:-}"; do
    [[ "${existing}" == "${url}" ]] && return 0
  done
  API_CANDIDATES+=("${url}")
}

# Build / refresh candidate list each poll.
# Order: mgmt Route (CI-stable) → LPAR NodePort → on-bridge addresses (RCA).
build_api_candidates() {
  local nodeport=""
  local lb_ip=""
  local node_ip=""
  local svc_type=""
  local cp_host=""
  local cp_port=""
  local route_host=""

  nodeport=$(oc get svc kube-apiserver -n "${HCP_NS}" \
    -o jsonpath="{.spec.ports[?(@.port==6443)].nodePort}" 2>/dev/null || true)
  lb_ip=$(oc get svc kube-apiserver -n "${HCP_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  svc_type=$(oc get svc kube-apiserver -n "${HCP_NS}" -o jsonpath='{.spec.type}' 2>/dev/null || true)
  node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  cp_host=$(oc get hc -n "${HC_NS}" "${HC_NAME}" -o jsonpath='{.status.controlPlaneEndpoint.host}' 2>/dev/null || true)
  cp_port=$(oc get hc -n "${HC_NS}" "${HC_NAME}" -o jsonpath='{.status.controlPlaneEndpoint.port}' 2>/dev/null || true)
  # kube-apiserver Route host (passthrough on mgmt ingress) — primary CI path.
  route_host=$(oc get route -n "${HCP_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' 2>/dev/null \
    | awk '/kube-apiserver|kas/ {print $2; exit}')
  if [[ -z "${route_host}" ]]; then
    route_host="${API_ROUTE_HOSTNAME}"
  fi

  API_CANDIDATES=()
  # 1) Management ingress Route — same *.apps path CI already uses successfully
  if [[ -n "${route_host}" ]]; then
    add_candidate "https://${route_host}"
  fi
  if [[ -n "${cp_host}" && "${cp_host}" =~ [a-zA-Z] ]]; then
    add_candidate "https://${cp_host}:${cp_port:-443}"
  fi
  # 2) LPAR:NodePort — historical VPN path (flaky across CI pods)
  if [[ -n "${LPAR_HOST_IP}" && -n "${nodeport}" ]]; then
    add_candidate "https://${LPAR_HOST_IP}:${nodeport}"
  fi
  # 3) mgmt node InternalIP:NodePort — on-bridge / RCA
  if [[ -n "${node_ip}" && -n "${nodeport}" ]]; then
    add_candidate "https://${node_ip}:${nodeport}"
  fi
  # 4) MetalLB VIP — on-bridge only; RCA
  if [[ -n "${lb_ip}" ]]; then
    add_candidate "https://${lb_ip}:6443"
  fi
  # 5) Original hcp kubeconfig server (often VIP — deduped)
  add_candidate "${ORIG_SERVER}"

  echo "$(date) Candidates type=${svc_type:-?} nodePort=${nodeport:-none} lb=${lb_ip:-none} nodeIP=${node_ip:-none} lpar=${LPAR_HOST_IP} route=${route_host:-none} cp=${cp_host:-none}:${cp_port:-}"
  local i=0
  for c in "${API_CANDIDATES[@]:-}"; do
    echo "$(date)   [$i] ${c}"
    i=$((i + 1))
  done

  # Once per ~2 minutes, probe guest API via port-forward for RCA
  # (distinguishes "external path down" from "guest apiserver down").
  if [[ $((${API_ELAPSED:-0} % 120)) -eq 0 ]]; then
    probe_readyz_via_portforward "${HCP_NS}" || true
    oc get route -n "${HCP_NS}" -o wide 2>/dev/null || true
  fi
}

select_reachable_api() {
  local elapsed=0
  local readyz=""
  local candidate=""
  local selected=""

  while [[ ${elapsed} -lt ${API_MAX_WAIT} ]]; do
    API_ELAPSED=${elapsed}
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
        printf '%s' "${selected}" > "${SHARED_DIR}/guest-api-server"
        echo "$(date) Wrote ${SHARED_DIR}/guest-api-server=${selected}"
        echo "$(date) Post-patch nested_kubeconfig:"
        oc --kubeconfig "${VIRT_KC}" config view || true
        # Confirm oc can talk to the guest with the patched kubeconfig
        if oc --kubeconfig "${VIRT_KC}" --request-timeout=30s get --raw=/readyz 2>/dev/null | grep -q '^ok$'; then
          echo "$(date) oc --kubeconfig nested_kubeconfig get --raw=/readyz => ok"
          return 0
        fi
        echo "$(date) WARNING: /readyz via curl was ok but oc get --raw=/readyz failed; dumping and continuing to retry"
        dump_ci_to_lpar_path
        dump_guest_debug
        selected=""
      fi
    fi
    # Path dump every ~5 minutes while waiting (VPN/MTU RCA).
    if [[ $((elapsed % 300)) -eq 0 ]]; then
      dump_ci_to_lpar_path
    fi
    sleep ${API_INTERVAL}
    elapsed=$((elapsed + API_INTERVAL))
  done

  echo "$(date) ERROR: No guest API endpoint returned /readyz=ok within ${API_MAX_WAIT}s"
  echo "$(date) DEBUG: kube-apiserver Service YAML:"
  oc get svc kube-apiserver -n "${HCP_NS}" -o yaml || true
  echo "$(date) DEBUG: EndpointSlices for kube-apiserver:"
  oc get endpointslice -n "${HCP_NS}" -o wide 2>/dev/null || true
  echo "$(date) DEBUG: final port-forward probe (mgmt tunnel):"
  probe_readyz_via_portforward "${HCP_NS}" || true
  dump_ci_to_lpar_path
  dump_mgmt_debug
  dump_guest_debug
  return 1
}

echo "$(date) NodePool status before API/node waits:"
dump_ci_to_lpar_path
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

echo "$(date) Create step complete — next steps (ibmz-test, then conformance) load ${SHARED_DIR}/nested_kubeconfig"
echo "$(date) NOTE: next CI pods get a fresh VPN; guest API may flake across steps even if create succeeded"
