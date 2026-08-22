#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc config view
oc projects
oc version

detect_bastion_platform() {
  local is_aws=false
  local is_baremetal=false

  if [[ "${CLUSTER_TYPE:-}" == "aws" ]] || [[ "${CLUSTER_PROFILE_NAME:-}" == aws-* ]] || [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
    is_aws=true
  fi
  if [[ "${CLUSTER_TYPE:-}" == metal* ]] || [[ "${CLUSTER_PROFILE_NAME:-}" == metal-* ]] || [[ -f "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key" ]]; then
    is_baremetal=true
  fi

  if [[ "${is_aws}" == true && "${is_baremetal}" == true ]]; then
    echo "ERROR: Ambiguous bastion platform detection (both AWS and bare metal markers found)"
    exit 1
  fi
  if [[ "${is_aws}" == true ]]; then
    BASTION_PLATFORM=aws
  elif [[ "${is_baremetal}" == true ]]; then
    BASTION_PLATFORM=baremetal
  else
    echo "ERROR: Could not detect bastion platform"
    exit 1
  fi
  echo "Detected bastion platform: ${BASTION_PLATFORM}"
}

run_without_xtrace() {
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  "$@"
  local rc=$?
  $WAS_TRACING && set -x
  return "${rc}"
}

init_bastion_connection() {
  case "${BASTION_PLATFORM}" in
    baremetal)
      [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
      set +x
      BASTION_SSH_KEY="${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
      BASTION_SSH_USER="root"
      BASTION_JUMPHOST=$(cat "${CLUSTER_PROFILE_DIR}/address")
      BASTION_HOST=$(cat "${CLUSTER_PROFILE_DIR}/bastion" 2>/dev/null || cat "${SHARED_DIR}/bastion")
      local ssh_args="-i ${BASTION_SSH_KEY} -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
      BASTION_SSH_OPTS=(-i "${BASTION_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o "ProxyCommand=ssh ${ssh_args} -W %h:%p root@${BASTION_JUMPHOST}")
      BASTION_HOME="/root"
      BASTION_RUN_SUDO=false
      TYPE=${TYPE:-mno}
      if [[ "${TYPE}" == "hmno" ]]; then
        BASTION_KUBECONFIG_PATH="/root/mno/kubeconfig"
      else
        BASTION_KUBECONFIG_PATH="/root/${TYPE}/kubeconfig"
      fi
      $WAS_TRACING && set -x
      ;;
    aws)
      [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
      set +x
      if [[ ! -f "${SHARED_DIR}/bastion_public_address" ]]; then
        $WAS_TRACING && set -x
        echo "ERROR: No bastion host found. Bastion provisioning may have failed."
        exit 1
      fi
      BASTION_HOST=$(cat "${SHARED_DIR}/bastion_public_address")

      if [[ -f "${SHARED_DIR}/bastion_ssh_user" ]]; then
        BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
      else
        BASTION_SSH_USER="core"
      fi

      local cluster_ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
      if [[ ! -f "${cluster_ssh_key}" ]]; then
        $WAS_TRACING && set -x
        echo "ERROR: Cluster profile SSH key not found at ${cluster_ssh_key}"
        exit 1
      fi

      BASTION_SSH_KEY="/tmp/bastion_ssh_key"
      cp "${cluster_ssh_key}" "${BASTION_SSH_KEY}"
      chmod 600 "${BASTION_SSH_KEY}"
      BASTION_SSH_OPTS=(-i "${BASTION_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null)
      BASTION_HOME="/var/home/core"
      BASTION_KUBECONFIG_PATH="${BASTION_HOME}/.kube/config"
      BASTION_RUN_SUDO=true
      $WAS_TRACING && set -x
      ;;
    *)
      echo "ERROR: Unknown bastion platform: ${BASTION_PLATFORM}"
      exit 1
      ;;
  esac
}

bastion_scp() {
  run_without_xtrace scp "${BASTION_SSH_OPTS[@]}" "$1" "${BASTION_SSH_USER}@${BASTION_HOST}:$2"
}

bastion_ssh() {
  run_without_xtrace ssh "${BASTION_SSH_OPTS[@]}" "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
}

setup_baremetal_bastion() {
  if [[ ! -f "${SHARED_DIR}/assignment_id" ]]; then
    return 0
  fi

  echo "Self-scheduling allocation detected, updating Go on bastion..."
  bastion_ssh bash -s <<'EOF'
sudo dnf install curl git mercurial make binutils bison gcc glibc-devel -y
bash < <(curl -sSL https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer)
source ~/.gvm/scripts/gvm
grep -q 'source ~/.gvm/scripts/gvm' ~/.bashrc || echo "source ~/.gvm/scripts/gvm" >> ~/.bashrc
gvm install go1.23
gvm use go1.23 --default
gvm install go1.25.0
rm -f ~/.gvm/environments/default
gvm use go1.25.0 --default
EOF
}

setup_aws_bastion() {
  bastion_ssh bash -s <<'EOF'
set -o errexit
set -o pipefail
export HOME="${HOME:-/var/home/core}"
TEMP_DIR="/tmp/evpn-bin"
GO_VERSION="${GO_VERSION:-1.25.0}"
GO_INSTALL_DIR="${TEMP_DIR}/go"
mkdir -p "${TEMP_DIR}/bin" "${HOME}/.cache/go-build" "${HOME}/go/bin"
export GOCACHE="${HOME}/.cache/go-build"
export GOPATH="${HOME}/go"
export PATH="${TEMP_DIR}/bin:${PATH}"

if ! command -v oc >/dev/null 2>&1; then
  curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz \
    | tar -xvzf - -C "${TEMP_DIR}/bin" oc kubectl
fi

if [[ ! -x "${GO_INSTALL_DIR}/bin/go" ]]; then
  echo "Installing Go ${GO_VERSION} to ${GO_INSTALL_DIR}..."
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C "${TEMP_DIR}" -xzf -
fi
export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
go version
EOF

  echo "Copying kubeconfig to AWS bastion..."
  bastion_ssh "export HOME=${BASTION_HOME}; mkdir -p ~/.kube && chmod 700 ~/.kube"
  bastion_scp "${SHARED_DIR}/kubeconfig" ".kube/config"
  bastion_ssh "export HOME=${BASTION_HOME}; chmod 600 ~/.kube/config"

  echo "Configuring AWS security group to allow port 179..."
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  INFRA_ID=$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)

  BASTION_INSTANCE_ID=""
  if [[ -f "${SHARED_DIR}/aws-instance-ids.txt" ]]; then
    BASTION_INSTANCE_ID=$(tail -1 "${SHARED_DIR}/aws-instance-ids.txt")
  fi

  SECURITY_GROUP_ID="unknown"
  if [[ -n "${BASTION_INSTANCE_ID}" ]]; then
    SECURITY_GROUP_ID=$(aws ec2 describe-instances \
      --instance-ids "${BASTION_INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "unknown")
  fi

  if [[ "${SECURITY_GROUP_ID}" == "None" || -z "${SECURITY_GROUP_ID}" || "${SECURITY_GROUP_ID}" == "unknown" ]]; then
    SECURITY_GROUP_ID=$(aws ec2 describe-instances \
      --filters "Name=dns-name,Values=${BASTION_HOST}" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "unknown")
  fi

  if [[ "${SECURITY_GROUP_ID}" == "None" || -z "${SECURITY_GROUP_ID}" || "${SECURITY_GROUP_ID}" == "unknown" ]]; then
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Name,Values=${INFRA_ID}-bastion-sg" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "unknown")
  fi

  open_bgp_port() {
    local sg_id=$1
    [[ "${sg_id}" == "unknown" || "${sg_id}" == "None" || -z "${sg_id}" ]] && return 0
    aws ec2 authorize-security-group-ingress \
      --group-id "${sg_id}" \
      --protocol tcp \
      --port 179 \
      --cidr 0.0.0.0/0 2>/dev/null || true
    if [[ -n "${SECURITY_GROUP_ID}" && "${SECURITY_GROUP_ID}" != "unknown" && "${SECURITY_GROUP_ID}" != "None" ]]; then
      aws ec2 authorize-security-group-ingress \
        --group-id "${sg_id}" \
        --protocol tcp \
        --port 179 \
        --source-group "${SECURITY_GROUP_ID}" 2>/dev/null || true
    fi
  }

  open_bgp_port "${SECURITY_GROUP_ID}"

  for sg_name in "${INFRA_ID}-worker-sg" "${INFRA_ID}-master-sg"; do
    NODE_SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Name,Values=${sg_name}" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "unknown")
    open_bgp_port "${NODE_SG_ID}"
  done
  $WAS_TRACING && set -x

  if [[ "${SECURITY_GROUP_ID:-}" != "unknown" && "${SECURITY_GROUP_ID:-}" != "None" ]]; then
    echo "Security group configured for port 179"
  else
    echo "Could not find bastion security group automatically"
    echo "Manual setup may be required to open port 179"
  fi
}

setup_bastion_for_platform() {
  case "${BASTION_PLATFORM}" in
    baremetal) setup_baremetal_bastion ;;
    aws) setup_aws_bastion ;;
  esac
}

run_bastion_frr_setup() {
  SETUP_SCRIPT_URL="https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/main/cmd/config/scripts/setup_external_frr_vrf.sh"
  CLEANUP_SCRIPT_URL="https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/main/cmd/config/scripts/cleanup_external_frr_vrf.sh"

  curl -fsSL -o /tmp/setup_external_frr_vrf.sh "${SETUP_SCRIPT_URL}"
  chmod +x /tmp/setup_external_frr_vrf.sh
  curl -fsSL -o /tmp/cleanup_external_frr_vrf.sh "${CLEANUP_SCRIPT_URL}"
  chmod +x /tmp/cleanup_external_frr_vrf.sh

  bastion_scp /tmp/setup_external_frr_vrf.sh /tmp/setup_external_frr_vrf.sh
  bastion_scp /tmp/cleanup_external_frr_vrf.sh /tmp/cleanup_external_frr_vrf.sh

  bastion_ssh env \
    HOME="${BASTION_HOME}" \
    KUBECONFIG_PATH="${BASTION_KUBECONFIG_PATH}" \
    BASTION_RUN_SUDO="${BASTION_RUN_SUDO}" \
    bash -s <<'EOF'
set -o errexit
set -o pipefail
export HOME="${HOME:-/var/home/core}"
BASTION_BIN_DIR="/tmp/evpn-bin/bin"
GO_VERSION="${GO_VERSION:-1.25.0}"
GO_INSTALL_DIR="/tmp/evpn-bin/go"
mkdir -p "${BASTION_BIN_DIR}" "${HOME}/.cache/go-build" "${HOME}/go/bin"
export GOCACHE="${HOME}/.cache/go-build"
export GOPATH="${HOME}/go"
export PATH="${BASTION_BIN_DIR}:${PATH}"
if ! command -v oc >/dev/null 2>&1; then
  curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz \
    | tar -xvzf - -C "${BASTION_BIN_DIR}" oc kubectl
fi
if [[ ! -x "${GO_INSTALL_DIR}/bin/go" ]]; then
  echo "Installing Go ${GO_VERSION} to ${GO_INSTALL_DIR}..."
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /tmp/evpn-bin -xzf -
fi
export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
if [[ -n "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
else
  export KUBECONFIG="${HOME}/.kube/config"
fi
bastion_run_cmd() {
  if [[ "${BASTION_RUN_SUDO:-false}" == "true" ]]; then
    sudo -E env "PATH=${PATH}" "HOME=${HOME}" "KUBECONFIG=${KUBECONFIG:-}" "GOCACHE=${GOCACHE}" "GOPATH=${GOPATH}" "$@"
  else
    "$@"
  fi
}
cd /tmp
bastion_run_cmd ./cleanup_external_frr_vrf.sh
EOF

  sleep 10

  bastion_ssh env \
    HOME="${BASTION_HOME}" \
    KUBECONFIG_PATH="${BASTION_KUBECONFIG_PATH}" \
    BASTION_RUN_SUDO="${BASTION_RUN_SUDO}" \
    ITERATIONS="${ITERATIONS}" \
    EXTERNAL_WEBSERVER_IP="${EXTERNAL_WEBSERVER_IP}" \
    L3VNI_START="${L3VNI_START}" \
    L2VNI_START="${L2VNI_START}" \
    bash -s <<'EOF'
set -o errexit
set -o pipefail
export HOME="${HOME:-/var/home/core}"
BASTION_BIN_DIR="/tmp/evpn-bin/bin"
GO_VERSION="${GO_VERSION:-1.25.0}"
GO_INSTALL_DIR="/tmp/evpn-bin/go"
mkdir -p "${BASTION_BIN_DIR}" "${HOME}/.cache/go-build" "${HOME}/go/bin"
export GOCACHE="${HOME}/.cache/go-build"
export GOPATH="${HOME}/go"
export PATH="${BASTION_BIN_DIR}:${PATH}"
if ! command -v oc >/dev/null 2>&1; then
  curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz \
    | tar -xvzf - -C "${BASTION_BIN_DIR}" oc kubectl
fi
if [[ ! -x "${GO_INSTALL_DIR}/bin/go" ]]; then
  echo "Installing Go ${GO_VERSION} to ${GO_INSTALL_DIR}..."
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /tmp/evpn-bin -xzf -
fi
export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
if [[ -n "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
else
  export KUBECONFIG="${HOME}/.kube/config"
fi
bastion_run_cmd() {
  if [[ "${BASTION_RUN_SUDO:-false}" == "true" ]]; then
    sudo -E env "PATH=${PATH}" "HOME=${HOME}" "KUBECONFIG=${KUBECONFIG:-}" "GOCACHE=${GOCACHE}" "GOPATH=${GOPATH}" "$@"
  else
    "$@"
  fi
}
cd /tmp
bastion_run_cmd ./setup_external_frr_vrf.sh "${ITERATIONS}" "${EXTERNAL_WEBSERVER_IP}" "${L3VNI_START}" "${L2VNI_START}"
EOF
}

# EVPN pre-setup (not GA, requires TechPreview and manual FRR configuration)

wait_for_network_operator_rollout() {
  # Progressing=True may never be observed when the patch is a no-op or
  # reconciliation finishes before oc wait starts, so treat it as optional.
  oc wait co/network --for=condition=Progressing=True --timeout=2m || true
  oc wait co/network --for=condition=Progressing=False --timeout=10m
  oc wait co/network --for=condition=Available=True --timeout=10m
}

# 1. Enable TechPreview feature gate
oc patch featuregate cluster --type=merge -p='{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'

for i in $(seq 1 60); do
  [[ "$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}')" == "TechPreviewNoUpgrade" ]] && break
  [[ "$i" -eq 60 ]] && { echo "Timed out waiting for TechPreview feature gate"; exit 1; }
  sleep 5
done
oc wait --for=condition=Available=True clusteroperators --all --timeout=15m

# 2. Set Local Gateway with Global forwarding
oc patch networks.operator.openshift.io cluster --type=merge -p \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
wait_for_network_operator_rollout

# 3. Enable FRR and Route Advertisements
oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]},"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
wait_for_network_operator_rollout

# 4. Upgrade FRR image (scale CVO down, set network operator unmanaged)
oc scale -n openshift-cluster-version deployment.apps/cluster-version-operator --replicas=0
oc patch Network.operator.openshift.io cluster --type='merge' -p='{"spec":{"managementState":"Unmanaged"}}'
oc set image daemonset/frr-k8s -n openshift-frr-k8s frr=${FRR_IMAGE} reloader=${FRR_IMAGE}
oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=5m

export ITERATIONS

# 5. Run external FRR/VRF setup on bastion
detect_bastion_platform
init_bastion_connection
setup_bastion_for_platform
run_bastion_frr_setup

# 6. Create VTEP resource
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  mode: Unmanaged
  cidrs:
    - ${VTEP_CIDR}
EOF

UUID=$(uuidgen)

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"
export ES_SERVER
unset ES_PASSWORD ES_USERNAME

$WAS_TRACING && set -x

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

if [[ -n "${SCENARIO}" ]]; then
  EXTRA_FLAGS+=" --scenario=${SCENARIO}"
fi

if [[ -n "${EXTERNAL_WEBSERVER_IP}" ]]; then
  EXTRA_FLAGS+=" --external-webserver-ip=${EXTERNAL_WEBSERVER_IP}"
fi

EXTRA_FLAGS+=" --profile-type=${PROFILE_TYPE}"

export WORKLOAD=evpn
export EXTRA_FLAGS UUID

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -f ${METRICS_FOLDER}/jobSummary.json ]]; then
  cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
  if [[ ${JOB_NAME} == *openshift-eng-ocp-qe-perfscale-ci* ]] && [[ ${JOB_TYPE} == "periodic" ]]; then
    set +e
    OCP_PERF_DASH_HOST=$(cat ${ES_SECRETS_PATH}/ocp-perf-dash-address)
    OCP_PERF_DASH_DIR="/usr/share/ocp-perf-dash/${JOB_NAME}/${WORKLOAD}/${UUID}"
    METRICS="${METRICS_FOLDER}/*QuantilesMeasurement*.json ${METRICS_FOLDER}/jobSummary.json"
    SSH_ARGS="-i ${ES_SECRETS_PATH}/ocp-perf-dash-id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh ${SSH_ARGS} ${OCP_PERF_DASH_HOST} "mkdir -p ${OCP_PERF_DASH_DIR}"
    scp ${SSH_ARGS} ${METRICS} ${OCP_PERF_DASH_HOST}:${OCP_PERF_DASH_DIR}
    set -e
  fi
fi

exit ${RUN_EXIT_CODE}
