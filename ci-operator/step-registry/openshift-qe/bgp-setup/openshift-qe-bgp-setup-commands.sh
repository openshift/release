#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -z "${NETWORK_WORKLOAD:-}" ]]; then
  echo "ERROR: NETWORK_WORKLOAD must be set to 'evpn' or 'udn-bgp'" >&2
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc version --client

# ---------------------------------------------------------------------------
# Bastion SSH helpers (same path for EVPN and UDN-BGP on both AWS and BM)
# ---------------------------------------------------------------------------
# Configure SSH access to the external FRR bastion on AWS or bare metal.
setup_bastion_ssh() {
  if [[ -f "${SHARED_DIR}/bastion_ssh_key" ]]; then
    BASTION_PLATFORM="aws"
    BASTION_SSH_KEY="/tmp/bastion_ssh_key"
    cp "${SHARED_DIR}/bastion_ssh_key" "${BASTION_SSH_KEY}"
    chmod 400 "${BASTION_SSH_KEY}"
    BASTION_HOST=$(cat "${SHARED_DIR}/bastion_public_address")
    BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user" 2>/dev/null || echo "root")
    SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null"
    BASTION_WORK_DIR="/root/${NETWORK_WORKLOAD}"
    if [[ -f "${SHARED_DIR}/bastion_private_address" ]]; then
      BASTION_PRIVATE_IP=$(cat "${SHARED_DIR}/bastion_private_address")
      echo "AWS bastion SSH configured (workdir: ${BASTION_WORK_DIR})"
    else
      echo "AWS bastion SSH configured (workdir: ${BASTION_WORK_DIR})"
    fi
  elif [[ -f "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key" ]]; then
    BASTION_PLATFORM="bm"
    BASTION_SSH_KEY="${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
    JUMPHOST=$(cat "${CLUSTER_PROFILE_DIR}/address")
    BASTION_HOST=$(cat "${CLUSTER_PROFILE_DIR}/bastion" 2>/dev/null || cat "${SHARED_DIR}/bastion")
    BASTION_SSH_USER="root"
    BASTION_WORK_DIR="/tmp"
    SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    TYPE=${TYPE:-mno}
    if [[ "${TYPE}" == "hmno" ]]; then
      BASTION_KUBECONFIG_PATH="/root/mno/kubeconfig"
    else
      BASTION_KUBECONFIG_PATH="/root/${TYPE}/kubeconfig"
    fi
    echo "BM bastion SSH configured via jumphost proxy"
  else
    echo "ERROR: No bastion SSH credentials found" >&2
    exit 1
  fi
}

# Run a command on the bastion, using a jumphost ProxyCommand on bare metal.
bastion_ssh() {
  if [[ -n "${JUMPHOST:-}" ]]; then
    ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${BASTION_SSH_USER}@${JUMPHOST}" "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
  else
    ssh ${SSH_ARGS} "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
  fi
}

# Copy files to or from the bastion, using a jumphost ProxyCommand on bare metal.
bastion_scp() {
  if [[ -n "${JUMPHOST:-}" ]]; then
    scp ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${BASTION_SSH_USER}@${JUMPHOST}" "$@"
  else
    scp ${SSH_ARGS} "$@"
  fi
}

# Wait for the cluster network operator to finish rolling out configuration changes.
wait_for_network_operator_rollout() {
  oc wait co/network --for=condition=Progressing=True --timeout=2m || true
  oc wait co/network --for=condition=Progressing=False --timeout=10m
  oc wait co/network --for=condition=Available=True --timeout=10m
}

# Enable FRR and route advertisements in the cluster network configuration.
enable_frr_and_route_advertisements() {
  echo "=== Enable FRR + Route Advertisements ==="
  oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]},"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
  wait_for_network_operator_rollout
}

# CNO keeps applying operands for a while after managementState is set to
# Unmanaged: a sync that started before the patch still renders frr-k8s and
# rewrites the statuscleaner Deployment afterwards. In the 300-CUDN rehearsal
# the operator rewrote the Deployment five seconds after ours, silently
# dropping the pprof arg; and because the rewrite restored a pod template whose
# ReplicaSet was already complete, "oc rollout status" reported success against
# pods that never carried the change. Hold the operator and wait for the
# Deployment to settle before touching it.
hold_frr_k8s_operator() {
  oc patch Network.operator.openshift.io cluster --type=merge \
    -p='{"spec":{"managementState":"Unmanaged"}}'
  oc wait co/network --for=condition=Progressing=False --timeout=5m || true

  local previous="" current="" stable=0 start=${SECONDS}
  while (( stable < 3 )); do
    if (( SECONDS - start > 180 )); then
      echo "WARN: deployment/frr-k8s-statuscleaner is still changing after 3m; continuing" >&2
      return
    fi
    current=$(oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s \
      -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null) || current=""
    if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    previous="${current}"
    sleep 5
  done
}

# True when the statuscleaner Deployment still carries the pprof arg. CNO
# rewrites this Deployment from its own render, so the state has to be
# re-checked after every rollout instead of being assumed.
statuscleaner_pprof_arg_present() {
  local pprof_arg="${1}"
  oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s -o json 2>/dev/null | jq -e \
    --arg pprof_arg "${pprof_arg}" '
      any(.spec.template.spec.containers[];
          .name == "frr-k8s-statuscleaner"
          and any((.args // [])[]; . == $pprof_arg))' >/dev/null
}

# Add the pprof arg to the statuscleaner Deployment. The arg must be prepended,
# not appended: CNO renders "--frrk8s-selector=..." followed by a bare
# "$(LOG_LEVEL)" positional argument, and Go's flag.Parse stops at the first
# non-flag token. Anything after that token (including a trailing
# --pprof-bind-address) is silently ignored and the listener never starts.
patch_statuscleaner_for_profile() {
  local pprof_arg="${1}" deployment_json patch
  deployment_json=$(oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s -o json)

  if ! jq -e 'any(.spec.template.spec.containers[]?; .name == "frr-k8s-statuscleaner")' \
      <<<"${deployment_json}" >/dev/null; then
    echo "ERROR: frr-k8s-statuscleaner container not found in deployment/frr-k8s-statuscleaner" >&2
    exit 1
  fi

  patch=$(jq -c --arg pprof_arg "${pprof_arg}" '
      (.spec.template.spec.containers | to_entries
        | map(select(.value.name == "frr-k8s-statuscleaner")) | first) as $c
      | ($c.key | tostring) as $i
      | ($c.value.args // []) as $args
      | [
          (if any($args[]; startswith("--pprof-bind-address")) then empty
           elif $c.value.args == null then
             {op: "add",
              path: ("/spec/template/spec/containers/" + $i + "/args"),
              value: [$pprof_arg]}
           else
             {op: "add",
              path: ("/spec/template/spec/containers/" + $i + "/args/0"),
              value: $pprof_arg}
           end)
        ]' <<<"${deployment_json}")

  if [[ "${patch}" == "[]" ]]; then
    echo "deployment/frr-k8s-statuscleaner already carries ${pprof_arg}"
    return
  fi

  echo "Patching deployment/frr-k8s-statuscleaner: ${patch}"
  oc patch deployment/frr-k8s-statuscleaner -n openshift-frr-k8s \
    --type=json -p="${patch}"
}

# Name of the Ready pod backing the Deployment's current revision, so a probe
# never lands on a stale ReplicaSet that is still terminating.
statuscleaner_current_pod() {
  local revision deployment_uid rs_uid
  revision=$(oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null) || return 1
  deployment_uid=$(oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s \
    -o jsonpath='{.metadata.uid}' 2>/dev/null) || return 1
  [[ -n "${revision}" && -n "${deployment_uid}" ]] || return 1
  rs_uid=$(oc get replicasets -n openshift-frr-k8s -o json 2>/dev/null \
    | jq -r --arg rev "${revision}" --arg deploy_uid "${deployment_uid}" '
        [.items[]
         | select(.metadata.deletionTimestamp == null)
         | select(.metadata.annotations["deployment.kubernetes.io/revision"] == $rev)
         | select(any(.metadata.ownerReferences[]?; .uid == $deploy_uid))]
        | .[0].metadata.uid // empty') || return 1
  [[ -n "${rs_uid}" ]] || return 1
  oc get pods -n openshift-frr-k8s -l component=frr-k8s-statuscleaner \
    --field-selector=status.phase=Running -o json 2>/dev/null \
    | jq -r --arg rs_uid "${rs_uid}" '
        [.items[]
         | select(.metadata.deletionTimestamp == null)
         | select(any(.metadata.ownerReferences[]?; .uid == $rs_uid))
         | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
        | .[0].metadata.name // empty'
}

# Expose the statuscleaner pprof endpoint so the FRRConfiguration validating
# webhook can be profiled live while a scale workload runs.
enable_frr_k8s_webhook_pprof() {
  if [[ "${FRR_K8S_WEBHOOK_PERF:-false}" != "true" ]]; then
    return
  fi

  echo "=== Enable frr-k8s statuscleaner pprof endpoint ==="

  if ! oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s >/dev/null 2>&1; then
    echo "ERROR: deployment/frr-k8s-statuscleaner not found; FRR must be enabled first" >&2
    exit 1
  fi

  hold_frr_k8s_operator

  local pprof_arg="--pprof-bind-address=127.0.0.1:6060"
  local attempt probe last_error="" pod=""

  # The frr-k8s image is alpine, so busybox wget is the portable way to prove
  # the pprof listener answers from inside the container network namespace.
  # CNO can still rewrite the operand shortly after the patch lands, so treat a
  # completed rollout as a hint only: re-check the Deployment spec and the pod
  # that is actually serving, and re-apply if the operator reverted us.
  for attempt in $(seq 1 6); do
    patch_statuscleaner_for_profile "${pprof_arg}"
    oc rollout status deployment/frr-k8s-statuscleaner -n openshift-frr-k8s --timeout=10m || true

    for probe in $(seq 1 60); do
      if ! statuscleaner_pprof_arg_present "${pprof_arg}"; then
        echo "WARN: deployment/frr-k8s-statuscleaner was rewritten after our patch (attempt ${attempt})" >&2
        break
      fi
      pod=$(statuscleaner_current_pod) || pod=""
      if [[ -z "${pod}" ]]; then
        sleep 2
        continue
      fi
      if last_error=$(oc exec -n openshift-frr-k8s "${pod}" -c frr-k8s-statuscleaner -- \
          wget -q -O /dev/null http://127.0.0.1:6060/debug/pprof/ 2>&1); then
        echo "frr-k8s statuscleaner pprof endpoint ready (pod ${pod}, attempt ${attempt})"
        return
      fi
      sleep 2
    done
    echo "WARN: pprof endpoint not reachable yet (attempt ${attempt}, last probe error: ${last_error:-none})" >&2
    sleep 15
  done

  echo "ERROR: pprof endpoint is not reachable in frr-k8s-statuscleaner after 6 attempts" >&2
  if [[ -n "${last_error}" ]]; then
    echo "last probe error: ${last_error}" >&2
  fi
  oc get deployment/frr-k8s-statuscleaner -n openshift-frr-k8s -o json \
    | jq '{revision: .metadata.annotations["deployment.kubernetes.io/revision"],
           containers: [.spec.template.spec.containers[] | {name, image, args}]}' >&2 || true
  oc get pods -n openshift-frr-k8s -l component=frr-k8s-statuscleaner -o wide >&2 || true
  if [[ -n "${pod}" ]]; then
    # Deployment args are unexpanded templates; show what the process really got.
    oc exec -n openshift-frr-k8s "${pod}" -c frr-k8s-statuscleaner -- \
      cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' >&2 || true
    echo >&2
    oc describe pod -n openshift-frr-k8s "${pod}" >&2 || true
    oc logs -n openshift-frr-k8s "${pod}" -c frr-k8s-statuscleaner --tail=50 >&2 || true
  fi
  exit 1
}

# Load platform-specific bastion environment variables for AWS or bare metal.
load_bastion_env_vars() {
  BASTION_EXTRA_ENV=()
  AWS_SETUP_ENV=()
  if [[ "${BASTION_PLATFORM}" == "bm" ]]; then
    BASTION_EXTRA_ENV=(KUBECONFIG="${BASTION_KUBECONFIG_PATH}")
  elif [[ -f "${SHARED_DIR}/evpn-bastion-resources.json" ]]; then
    BASTION_PRIVATE_IP=$(jq -r '.bastion_private_ip // empty' "${SHARED_DIR}/evpn-bastion-resources.json" 2>/dev/null || true)
    NODE_SUBNET_CIDR=$(jq -r '.machine_network_cidr // .worker_subnet_cidr // empty' "${SHARED_DIR}/evpn-bastion-resources.json" 2>/dev/null || true)
    if [[ -n "${BASTION_PRIVATE_IP}" && -n "${NODE_SUBNET_CIDR}" ]]; then
      echo "AWS ${NETWORK_WORKLOAD}: loaded bastion network environment from evpn-bastion-resources.json"
      AWS_SETUP_ENV=(BASTION_PRIVATE_IP="${BASTION_PRIVATE_IP}" NODE_SUBNET_CIDR="${NODE_SUBNET_CIDR}")
    fi
  fi
  # Fall back: when evpn-bastion-resources.json is absent, forward BASTION_PRIVATE_IP
  # already set by setup_bastion_ssh (from SHARED_DIR/bastion_private_address) so that
  # setup_external_frr_udn_bgp passes the correct AWS gateway to the remote demo.sh.
  if [[ "${BASTION_PLATFORM}" == "aws" && ${#AWS_SETUP_ENV[@]} -eq 0 && -n "${BASTION_PRIVATE_IP:-}" ]]; then
    AWS_SETUP_ENV=(BASTION_PRIVATE_IP="${BASTION_PRIVATE_IP}")
    [[ -n "${NODE_SUBNET_CIDR:-}" ]] && AWS_SETUP_ENV+=(NODE_SUBNET_CIDR="${NODE_SUBNET_CIDR}")
  fi
}

# Poll the external FRR container until at least one BGP session is Established.
wait_for_bgp_established() {
  echo "=== Waiting for BGP sessions to establish ==="
  local bgp_established=false
  local attempt
  for attempt in $(seq 1 36); do
    if bastion_ssh "podman exec frr vtysh \
      -c 'show bgp neighbors'" 2>/dev/null | grep -q "BGP state = Established"; then
      echo "BGP sessions are Established (attempt ${attempt})"
      bgp_established=true
      break
    fi
    if [[ "${attempt}" -eq 1 || $((attempt % 6)) -eq 0 ]]; then
      echo "BGP sessions not yet Established (attempt ${attempt}/36)..."
    fi
    sleep 10
  done

  if [[ "${bgp_established}" != "true" ]]; then
    echo "ERROR: No BGP sessions reached Established state after 6 minutes." >&2
    bastion_ssh "podman exec frr vtysh \
      -c 'show bgp summary' \
      -c 'show bgp neighbors'" 2>&1 || true
    oc get frrconfigurations -n openshift-frr-k8s -o yaml 2>&1 || true
    exit 1
  fi
}

# Write the external FRR peer address to SHARED_DIR for downstream workload steps.
write_frr_peer_address() {
  local peer_ip=""
  if [[ "${BASTION_PLATFORM}" == "aws" ]]; then
    if [[ -f "${SHARED_DIR}/bastion_private_address" ]]; then
      peer_ip=$(cat "${SHARED_DIR}/bastion_private_address")
    elif [[ -f "${SHARED_DIR}/evpn-bastion-resources.json" ]]; then
      peer_ip=$(jq -r '.bastion_private_ip // empty' "${SHARED_DIR}/evpn-bastion-resources.json" 2>/dev/null || true)
    fi
  else
    # BM SSH target is a hostname. kube-burner requires the IPv4 FRR is
    # actually peering on, which demo.sh writes into receive-all.
    peer_ip=$(oc get frrconfiguration receive-all -n openshift-frr-k8s \
      -o jsonpath='{.spec.bgp.routers[0].neighbors[0].address}' 2>/dev/null || true)
    peer_ip=$(tr -d '[:space:]' <<< "${peer_ip}")
  fi

  if [[ -z "${peer_ip}" ]]; then
    echo "ERROR: Could not determine FRR peer address for ${NETWORK_WORKLOAD}" >&2
    exit 1
  fi

  echo "${peer_ip}" > "${SHARED_DIR}/frr-peer-address"
  echo "Wrote FRR peer address to ${SHARED_DIR}/frr-peer-address"
}

# Patch the upstream EVPN setup script for AWS bastion and demo.sh compatibility.
patch_setup_external_frr_vrf() {
  local setup_script=$1
  local tmp_script
  tmp_script="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == *"oc apply"*"receive_all.yaml"* ]]; then
      cat <<'EVPN_PATCH'
sed -i '/disableMP: true/d' frr-k8s/hack/demo/configs/receive_all.yaml
EVPN_PATCH
    fi
    if [[ "${line}" == 'NODE_SUBNET_CIDR=""' ]]; then
      cat <<'AWS_IP_PATCH'
if [[ -n "${BASTION_PRIVATE_IP:-}" && -n "${NODE_SUBNET_CIDR:-}" ]]; then
  LOCAL_IP="${BASTION_PRIVATE_IP}"
else
AWS_IP_PATCH
    fi
    if [[ "${line}" == 'if [[ -z "$LOCAL_IP" ]]; then' ]]; then
      cat <<'AWS_IP_PATCH_END'
fi
AWS_IP_PATCH_END
    fi
    printf '%s\n' "${line}"
    if [[ "${line}" == *"git clone -b ovnk-bgp"* ]]; then
      cat <<'DEMO_PATCH'
sed -i '/frr-extranet/s/^/# /' frr-k8s/hack/demo/demo.sh
sed -i 's/ --rm --ulimit/ --ulimit/' frr-k8s/hack/demo/demo.sh
if [[ -n "${BASTION_PRIVATE_IP:-}" ]]; then
  python3 - <<'PY' || exit 1
import pathlib
import sys

p = pathlib.Path("frr-k8s/hack/demo/demo.sh")
text = p.read_text()
old = """for node in $NODE_IPS_V4; do
    getNodeGatewayAndNetwork "ip" "$node"
    GW_IP_V4=$GW_IP
    PREFIX_V4=$PREFIX
    break
done"""
new = """if [[ -n "${BASTION_PRIVATE_IP:-}" ]]; then
    GW_IP_V4="${BASTION_PRIVATE_IP}"
    GW_IP="${BASTION_PRIVATE_IP}"
    NETWORK=host
    if [[ "${NODE_SUBNET_CIDR:-}" == */* ]]; then
        PREFIX_V4="${NODE_SUBNET_CIDR#*/}"
    fi
    echo "Using AWS worker ENI for external FRR configuration"
else
    for node in $NODE_IPS_V4; do
        getNodeGatewayAndNetwork "ip" "$node"
        GW_IP_V4=$GW_IP
        PREFIX_V4=$PREFIX
        break
    done
fi"""
if old not in text:
    sys.stderr.write("demo.sh: IPv4 gateway loop not found\n")
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
PY
fi
DEMO_PATCH
    fi
    if [[ "${line}" == *"pushd frr-k8s/hack/demo"*"./demo.sh"* ]]; then
      cat <<'FRR_WAIT'
for _i in $(seq 1 30); do
  if podman exec frr vtysh -c "show version" >/dev/null 2>&1; then
    break
  fi
  [ "${_i}" -eq 30 ] && echo "WARNING: FRR daemon not ready after 60s — vtysh may fail" && break
  sleep 2
done
FRR_WAIT
    fi
  done < "${setup_script}" > "${tmp_script}"
  mv "${tmp_script}" "${setup_script}"
}

# Verify the external FRR container is running on the bastion.
validate_bastion_frr_setup() {
  if ! bastion_ssh "podman inspect -f '{{.State.Running}}' frr 2>/dev/null | grep -q true"; then
    echo "ERROR: external FRR container 'frr' is not running on bastion" >&2
    bastion_ssh "podman ps -a" || true
    exit 1
  fi
}

# Validate external FRR and wait for cluster-side BGP sessions to establish.
finalize_bgp_setup() {
  validate_bastion_frr_setup
  oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=3m || true
  wait_for_bgp_established
}

# ---------------------------------------------------------------------------
# EVPN-only cluster prerequisites (before common BGP steps)
# ---------------------------------------------------------------------------
# Enable TechPreview features and local gateway routing required for EVPN.
setup_evpn_cluster_prereqs() {
  echo "=== EVPN cluster prerequisites ==="
  echo "=== Enable TechPreview ==="
  oc patch featuregate cluster --type=merge -p='{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'

  echo "=== Set Local Gateway + Global forwarding ==="
  oc patch networks.operator.openshift.io cluster --type=merge -p \
    '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
  wait_for_network_operator_rollout
}

# Upgrade the in-cluster FRR daemonset image and wait for rollout completion.
upgrade_frr_image() {
  echo "=== Upgrade FRR image ==="
  oc scale -n openshift-cluster-version deployment.apps/cluster-version-operator --replicas=0
  oc patch Network.operator.openshift.io cluster --type='merge' -p='{"spec":{"managementState":"Unmanaged"}}'
  oc set image daemonset/frr-k8s -n openshift-frr-k8s frr="${FRR_IMAGE}" reloader="${FRR_IMAGE}"
  oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=5m
}

# ---------------------------------------------------------------------------
# Common cluster BGP steps (both EVPN and UDN-BGP)
# ---------------------------------------------------------------------------
# Enable FRR route advertisements and roll out workload-specific cluster changes.
setup_common_cluster_bgp() {
  echo "=== Common cluster BGP setup for ${NETWORK_WORKLOAD} ==="
  enable_frr_and_route_advertisements

  if [[ "${NETWORK_WORKLOAD}" == "evpn" ]]; then
    upgrade_frr_image
  else
    oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=10m
    oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=15m
  fi
}

# ---------------------------------------------------------------------------
# Workload-specific external FRR on bastion
# ---------------------------------------------------------------------------
# Deploy and configure external FRR for EVPN using the upstream VRF setup script.
setup_external_frr_evpn() {
  echo "=== Setup external FRR on bastion (EVPN) ==="
  export ITERATIONS

  bastion_ssh "mkdir -p ${BASTION_WORK_DIR}"

  SETUP_SCRIPT_URL="https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/main/cmd/config/scripts/setup_external_frr_vrf.sh"
  CLEANUP_SCRIPT_URL="https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/main/cmd/config/scripts/cleanup_external_frr_vrf.sh"

  curl -fsSL -o /tmp/setup_external_frr_vrf.sh "${SETUP_SCRIPT_URL}"
  chmod +x /tmp/setup_external_frr_vrf.sh
  patch_setup_external_frr_vrf /tmp/setup_external_frr_vrf.sh
  curl -fsSL -o /tmp/cleanup_external_frr_vrf.sh "${CLEANUP_SCRIPT_URL}"
  chmod +x /tmp/cleanup_external_frr_vrf.sh

  BASTION_SCRIPT_DIR="${BASTION_WORK_DIR}"
  bastion_scp /tmp/setup_external_frr_vrf.sh "${BASTION_SSH_USER}@${BASTION_HOST}:${BASTION_SCRIPT_DIR}/setup_external_frr_vrf.sh"
  bastion_scp /tmp/cleanup_external_frr_vrf.sh "${BASTION_SSH_USER}@${BASTION_HOST}:${BASTION_SCRIPT_DIR}/cleanup_external_frr_vrf.sh"
  bastion_ssh "chmod +x ${BASTION_SCRIPT_DIR}/setup_external_frr_vrf.sh ${BASTION_SCRIPT_DIR}/cleanup_external_frr_vrf.sh"

  bastion_ssh env "${BASTION_EXTRA_ENV[@]}" "${AWS_SETUP_ENV[@]}" \
    ITERATIONS="${ITERATIONS}" \
    bash -s <<EOF
set -o errexit
set -o pipefail
cd ${BASTION_SCRIPT_DIR}
./cleanup_external_frr_vrf.sh "\${ITERATIONS}" || true
EOF

  sleep 10

  bastion_ssh env "${BASTION_EXTRA_ENV[@]}" "${AWS_SETUP_ENV[@]}" \
    ITERATIONS="${ITERATIONS}" \
    EXTERNAL_WEBSERVER_IP="${EXTERNAL_WEBSERVER_IP}" \
    L3VNI_START="${L3VNI_START}" \
    L2VNI_START="${L2VNI_START}" \
    bash -s <<EOF
set -o errexit
set -o pipefail
cd ${BASTION_SCRIPT_DIR}
./setup_external_frr_vrf.sh "\${ITERATIONS}" "\${EXTERNAL_WEBSERVER_IP}" "\${L3VNI_START}" "\${L2VNI_START}"
EOF
}

# Deploy and configure external FRR for UDN-BGP workload route redistribution.
setup_external_frr_udn_bgp() {
  echo "=== Setup external FRR on bastion (UDN-BGP) ==="
  bastion_ssh "mkdir -p ${BASTION_WORK_DIR}"

  bastion_ssh env "${BASTION_EXTRA_ENV[@]}" "${AWS_SETUP_ENV[@]}" \
    BASTION_WORK_DIR="${BASTION_WORK_DIR}" \
    UDN_BGP_IMPORT_CIDR="${UDN_BGP_IMPORT_CIDR}" \
    bash -s <<'EOF'
set -o errexit
set -o pipefail
cd "${BASTION_WORK_DIR}"

podman stop frr >/dev/null 2>&1 || true
podman rm -f frr >/dev/null 2>&1 || true
sleep 5
ip -o link show | awk -F': ' '{print $2}' | grep '^dummy' | xargs -r -I {} ip link delete {} || true
ip route show proto bgp | grep '^40\.' | awk '{print $1}' | xargs -r -I {} ip route del {} || true
rm -rf frr-k8s
sleep 5

git clone -b ovnk-bgp https://github.com/jcaamano/frr-k8s
sed -i '/frr-extranet/s/^/# /' frr-k8s/hack/demo/demo.sh
sed -i 's/ --rm --ulimit/ --ulimit/' frr-k8s/hack/demo/demo.sh

if [[ -n "${BASTION_PRIVATE_IP:-}" ]]; then
  python3 - <<'PY' || exit 1
import pathlib
import sys

p = pathlib.Path("frr-k8s/hack/demo/demo.sh")
text = p.read_text()
old = """for node in $NODE_IPS_V4; do
    getNodeGatewayAndNetwork "ip" "$node"
    GW_IP_V4=$GW_IP
    PREFIX_V4=$PREFIX
    break
done"""
new = """if [[ -n "${BASTION_PRIVATE_IP:-}" ]]; then
    GW_IP_V4="${BASTION_PRIVATE_IP}"
    GW_IP="${BASTION_PRIVATE_IP}"
    NETWORK=host
    if [[ "${NODE_SUBNET_CIDR:-}" == */* ]]; then
        PREFIX_V4="${NODE_SUBNET_CIDR#*/}"
    fi
    echo "Using AWS worker ENI for external FRR configuration"
else
    for node in $NODE_IPS_V4; do
        getNodeGatewayAndNetwork "ip" "$node"
        GW_IP_V4=$GW_IP
        PREFIX_V4=$PREFIX
        break
    done
fi"""
if old not in text:
    sys.stderr.write("demo.sh: IPv4 gateway loop not found\n")
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
PY
fi

pushd frr-k8s/hack/demo
./demo.sh
popd

for _i in $(seq 1 30); do
  if podman exec frr vtysh -c "show version" >/dev/null 2>&1; then
    break
  fi
  [ "${_i}" -eq 30 ] && echo "WARNING: FRR daemon not ready after 60s" && break
  sleep 2
done

oc apply -n openshift-frr-k8s -f frr-k8s/hack/demo/configs/receive_all.yaml
sleep 5
# The workload adds 20.<dummy-interface>.<address>.1/24 to dummy interfaces.
# Only redistribute those test routes; the bastion's underlay routes must stay local.
podman exec -u root frr vtysh \
  -c "conf t" \
  -c "ip prefix-list UDN-BGP-IMPORT seq 10 permit ${UDN_BGP_IMPORT_CIDR} ge 24 le 24" \
  -c "route-map UDN-BGP-IMPORT permit 10" \
  -c "match ip address prefix-list UDN-BGP-IMPORT" -c "exit" \
  -c "router bgp 64512" -c "address-family ipv4 unicast" \
  -c "no redistribute static" -c "no redistribute connected" \
  -c "redistribute connected route-map UDN-BGP-IMPORT" \
  -c "end" -c "write"
rm -rf frr-k8s
EOF
}

# Create the EVPN VTEP custom resource on bare metal clusters.
create_evpn_vtep() {
  if [[ "${BASTION_PLATFORM}" != "aws" ]]; then
    echo "=== Create VTEP (EVPN BM) ==="
    cat <<VTEPEOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  mode: Unmanaged
  cidrs:
    - ${VTEP_CIDR}
VTEPEOF
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
setup_bastion_ssh
load_bastion_env_vars

if [[ "${NETWORK_WORKLOAD}" == "evpn" ]]; then
  setup_evpn_cluster_prereqs
fi

setup_common_cluster_bgp
enable_frr_k8s_webhook_pprof

case "${NETWORK_WORKLOAD}" in
  evpn)
    setup_external_frr_evpn
    finalize_bgp_setup
    create_evpn_vtep
    ;;
  udn-bgp)
    setup_external_frr_udn_bgp
    finalize_bgp_setup
    write_frr_peer_address
    ;;
  *)
    echo "ERROR: Unsupported NETWORK_WORKLOAD '${NETWORK_WORKLOAD}'" >&2
    exit 1
    ;;
esac

echo "=== BGP setup complete for ${NETWORK_WORKLOAD} ==="
