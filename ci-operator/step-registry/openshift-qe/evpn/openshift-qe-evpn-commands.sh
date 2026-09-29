#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc version --client

# ---------------------------------------------------------------------------
# Bastion SSH helpers
# ---------------------------------------------------------------------------
setup_bastion_ssh() {
  if [[ -f "${SHARED_DIR}/bastion_ssh_key" ]]; then
    BASTION_PLATFORM="aws"
    BASTION_SSH_KEY="/tmp/bastion_ssh_key"
    cp "${SHARED_DIR}/bastion_ssh_key" "${BASTION_SSH_KEY}"
    chmod 400 "${BASTION_SSH_KEY}"
    BASTION_HOST=$(cat "${SHARED_DIR}/bastion_public_address")
    BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user" 2>/dev/null || echo "root")
    SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null"
    BASTION_WORK_DIR="/root/evpn"
    if [[ -f "${SHARED_DIR}/bastion_private_address" ]]; then
      BASTION_PRIVATE_IP=$(cat "${SHARED_DIR}/bastion_private_address")
      echo "AWS bastion: ${BASTION_SSH_USER}@${BASTION_HOST} (EVPN private IP: ${BASTION_PRIVATE_IP}, workdir: ${BASTION_WORK_DIR})"
    else
      echo "AWS bastion: ${BASTION_SSH_USER}@${BASTION_HOST} (workdir: ${BASTION_WORK_DIR})"
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
    echo "BM bastion: ${BASTION_SSH_USER}@${BASTION_HOST} via jumphost ${JUMPHOST}"
  else
    echo "ERROR: No bastion SSH credentials found" >&2
    exit 1
  fi
}

bastion_ssh() {
  if [[ -n "${JUMPHOST:-}" ]]; then
    ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${BASTION_SSH_USER}@${JUMPHOST}" "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
  else
    ssh ${SSH_ARGS} "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
  fi
}

bastion_scp() {
  if [[ -n "${JUMPHOST:-}" ]]; then
    scp ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${BASTION_SSH_USER}@${JUMPHOST}" "$@"
  else
    scp ${SSH_ARGS} "$@"
  fi
}

wait_for_network_operator_rollout() {
  oc wait co/network --for=condition=Progressing=True --timeout=2m || true
  oc wait co/network --for=condition=Progressing=False --timeout=10m
  oc wait co/network --for=condition=Available=True --timeout=10m
}

# Patch setup_external_frr_vrf.sh before it runs on the bastion:
# - comment out the broken frr-extranet container line in demo.sh
# - remove --rm so the frr container persists after demo.sh exits (needed for validation)
# - wait for FRR daemon init before vtysh runs (avoids EAGAIN/errno-11 on frr.conf)
# - strip disableMP from receive_all.yaml so frr-k8s negotiates L2VPN EVPN with bastion
# - on AWS, use provisioned BASTION_PRIVATE_IP + NODE_SUBNET_CIDR instead of broken auto-detect
# - on AWS, patch demo.sh to use BASTION_PRIVATE_IP (worker ENI) instead of primary public ENI
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
# AWS dual-ENI: demo.sh auto-detects the primary (public) ENI; use worker-subnet IP for BGP/FRR.
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
    echo "Using AWS worker ENI for FRR: ${GW_IP_V4} (VTEP CIDR prefix /${PREFIX_V4:-?})"
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

validate_bastion_frr_setup() {
  if ! bastion_ssh "podman inspect -f '{{.State.Running}}' frr 2>/dev/null | grep -q true"; then
    echo "ERROR: external FRR container 'frr' is not running on bastion" >&2
    bastion_ssh "podman ps -a" || true
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# EVPN pre-setup (not GA, requires TechPreview and manual FRR configuration)
# ---------------------------------------------------------------------------

setup_bastion_ssh

# 1. Enable TechPreview feature gate
echo "=== Step 1: Enable TechPreview ==="
oc patch featuregate cluster --type=merge -p='{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'

# 2. Set Local Gateway with Global forwarding
echo "=== Step 2: Set Local Gateway + Global forwarding ==="
oc patch networks.operator.openshift.io cluster --type=merge -p \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
wait_for_network_operator_rollout

# 3. Enable FRR and Route Advertisements
echo "=== Step 3: Enable FRR + Route Advertisements ==="
oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]},"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
wait_for_network_operator_rollout

# 4. Upgrade FRR image (scale CVO down, set network operator unmanaged)
echo "=== Step 4: Upgrade FRR image ==="
oc scale -n openshift-cluster-version deployment.apps/cluster-version-operator --replicas=0
oc patch Network.operator.openshift.io cluster --type='merge' -p='{"spec":{"managementState":"Unmanaged"}}'
oc set image daemonset/frr-k8s -n openshift-frr-k8s frr="${FRR_IMAGE}" reloader="${FRR_IMAGE}"
oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=5m

export ITERATIONS

# 5. Run external FRR/VRF setup on bastion
echo "=== Step 5: Setup external FRR on bastion ==="

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

# BM bastion keeps kubeconfig at a non-default path; AWS has it at /root/.kube/config
# (copied during openshift-qe-installer-aws-provision-bastion).
BASTION_EXTRA_ENV=()
AWS_SETUP_ENV=()
if [[ "${BASTION_PLATFORM}" == "bm" ]]; then
  BASTION_EXTRA_ENV=(KUBECONFIG="${BASTION_KUBECONFIG_PATH}")
elif [[ -f "${SHARED_DIR}/evpn-bastion-resources.json" ]]; then
  BASTION_PRIVATE_IP=$(jq -r '.bastion_private_ip // empty' "${SHARED_DIR}/evpn-bastion-resources.json" 2>/dev/null || true)
  # VTEP must cover all worker node underlay IPs — use machine/VPC CIDR, not a single subnet /18.
  NODE_SUBNET_CIDR=$(jq -r '.machine_network_cidr // .worker_subnet_cidr // empty' "${SHARED_DIR}/evpn-bastion-resources.json" 2>/dev/null || true)
  if [[ -n "${BASTION_PRIVATE_IP}" && -n "${NODE_SUBNET_CIDR}" ]]; then
    echo "AWS EVPN: bastion private IP=${BASTION_PRIVATE_IP}, VTEP CIDR=${NODE_SUBNET_CIDR}"
    AWS_SETUP_ENV=(BASTION_PRIVATE_IP="${BASTION_PRIVATE_IP}" NODE_SUBNET_CIDR="${NODE_SUBNET_CIDR}")
  fi
fi

# Cleanup first (idempotent)
bastion_ssh env "${BASTION_EXTRA_ENV[@]}" "${AWS_SETUP_ENV[@]}" \
  ITERATIONS="${ITERATIONS}" \
  bash -s <<EOF
set -o errexit
set -o pipefail
cd ${BASTION_SCRIPT_DIR}
./cleanup_external_frr_vrf.sh "\${ITERATIONS}" || true
EOF

sleep 10

# Setup external FRR/VRF on bastion
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

validate_bastion_frr_setup

# After applying receive_all.yaml frr-k8s needs time to reconcile on every node
# (regenerate frr.conf + reload FRR). Without this wait the bastion's BGP TCP
# SYNs hit nodes that haven't configured the bastion as a neighbor yet and are
# silently dropped, leaving all sessions stuck in Active state.
oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=3m || true

# Wait up to 6 minutes for at least one BGP session to reach Established.
# NOTE: "show bgp summary" in FRR prints a NUMBER (e.g. "0") in the
# State/PfxRcd column when a session is Established — the word "Established"
# only appears in "show bgp neighbors". We use the latter for reliable detection.
echo "=== Waiting for BGP sessions to establish ==="
BGP_ESTABLISHED=false
for _bgp_wait in $(seq 1 36); do
  if bastion_ssh "podman exec frr vtysh \
    -c 'show bgp neighbors'" 2>/dev/null | grep -q "BGP state = Established"; then
    echo "BGP sessions are Established (attempt ${_bgp_wait})"
    BGP_ESTABLISHED=true
    break
  fi
  if [[ "${_bgp_wait}" -eq 1 || $((_bgp_wait % 6)) -eq 0 ]]; then
    echo "BGP sessions not yet Established (attempt ${_bgp_wait}/36)..."
  fi
  sleep 10
done

if [[ "${BGP_ESTABLISHED}" != "true" ]]; then
  echo "ERROR: No BGP sessions reached Established state after 6 minutes." >&2
  echo "Dumping diagnostics for root cause analysis..." >&2
  bastion_ssh "podman exec frr vtysh \
    -c 'show bgp summary' \
    -c 'show bgp neighbors' \
    -c 'show bgp l2vpn evpn'" 2>&1 || true
  oc get frrconfigurations -n openshift-frr-k8s -o yaml 2>&1 || true
  oc exec -n openshift-frr-k8s daemonset/frr-k8s -c frr -- \
    vtysh -c "show bgp summary" -c "show bgp neighbors" 2>&1 || true
  exit 1
fi

# 6. Create VTEP resource (BM only — AWS setup script creates VTEP)
if [[ "${BASTION_PLATFORM}" != "aws" ]]; then
  echo "=== Step 6: Create VTEP ==="
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

# ---------------------------------------------------------------------------
# Run kube-burner workload
# ---------------------------------------------------------------------------
echo "=== Step 7: Run kube-burner EVPN workload ==="

UUID=$(uuidgen)

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}
ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [[ -e "${ES_SECRETS_PATH}/host" ]]; then
  ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags "${REPO_URL}.git" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [[ "${E2E_VERSION}" == "default" ]]; then echo "${LATEST_TAG}"; else echo "${E2E_VERSION}"; fi)"
git clone "${REPO_URL}" ${TAG_OPTION} --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

if [[ -n "${SCENARIO}" ]]; then
  EXTRA_FLAGS+=" --scenario=${SCENARIO}"
fi

if [[ -n "${EXTERNAL_WEBSERVER_IP}" ]]; then
  EXTRA_FLAGS+=" --external-webserver-ip=${EXTERNAL_WEBSERVER_IP}"
fi

EXTRA_FLAGS+=" --profile-type=${PROFILE_TYPE}"

export ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"
export WORKLOAD=evpn
export EXTRA_FLAGS UUID

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -f "${METRICS_FOLDER}/jobSummary.json" ]]; then
  cp -r "${METRICS_FOLDER}" "${ARTIFACT_DIR}/"
  if [[ "${JOB_NAME}" == *openshift-eng-ocp-qe-perfscale-ci* ]] && [[ "${JOB_TYPE}" == "periodic" ]]; then
    set +e
    OCP_PERF_DASH_HOST=$(cat "${ES_SECRETS_PATH}/ocp-perf-dash-address")
    OCP_PERF_DASH_DIR="/usr/share/ocp-perf-dash/${JOB_NAME}/${WORKLOAD}/${UUID}"
    METRICS="${METRICS_FOLDER}/*QuantilesMeasurement*.json ${METRICS_FOLDER}/jobSummary.json"
    DASH_SSH_ARGS="-i ${ES_SECRETS_PATH}/ocp-perf-dash-id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh ${DASH_SSH_ARGS} "${OCP_PERF_DASH_HOST}" "mkdir -p ${OCP_PERF_DASH_DIR}"
    scp ${DASH_SSH_ARGS} ${METRICS} "${OCP_PERF_DASH_HOST}:${OCP_PERF_DASH_DIR}"
    set -e
  fi
fi

exit ${RUN_EXIT_CODE}
