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

# EVPN pre-setup (not GA, requires TechPreview and manual FRR configuration)

wait_for_network_operator_rollout() {
  # Wait for reconciliation to start before waiting for it to finish.
  oc wait co/network --for=condition=Progressing=True --timeout=2m
  oc wait co/network --for=condition=Progressing=False --timeout=10m
}

# 1. Enable TechPreview feature gate
oc patch featuregate cluster --type=merge -p='{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'

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

# 5. Run external FRR/VRF setup on bastion
SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
jumphost=$(cat "${CLUSTER_PROFILE_DIR}/address")
bastion=$(cat "${CLUSTER_PROFILE_DIR}/bastion" 2>/dev/null || cat "${SHARED_DIR}/bastion")
TYPE=${TYPE:-mno}
if [[ "${TYPE}" == "hmno" ]]; then
  KUBECONFIG_PATH="/root/mno/kubeconfig"
else
  KUBECONFIG_PATH="/root/${TYPE}/kubeconfig"
fi
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/main/cmd/config/scripts/setup_external_frr_vrf.sh"
CLEANUP_SCRIPT_URL="https://raw.githubusercontent.com/kube-burner/kube-burner-ocp/main/cmd/config/scripts/cleanup_external_frr_vrf.sh"

curl -fsSL -o /tmp/setup_external_frr_vrf.sh "${SETUP_SCRIPT_URL}"
chmod +x /tmp/setup_external_frr_vrf.sh
curl -fsSL -o /tmp/cleanup_external_frr_vrf.sh "${CLEANUP_SCRIPT_URL}"
chmod +x /tmp/cleanup_external_frr_vrf.sh

scp ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${jumphost}" \
  /tmp/setup_external_frr_vrf.sh "root@${bastion}:/tmp/setup_external_frr_vrf.sh"
scp ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${jumphost}" \
  /tmp/cleanup_external_frr_vrf.sh "root@${bastion}:/tmp/cleanup_external_frr_vrf.sh"

# Update Go on bastion for self-scheduling allocations
if [[ -f "${SHARED_DIR}/assignment_id" ]]; then
  echo "Self-scheduling allocation detected, updating Go on bastion..."
  ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${jumphost}" "root@${bastion}" bash -s <<'EOF'
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
fi

# Cleanup external FRR/VRF setup on bastion
ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${jumphost}" "root@${bastion}" env \
  KUBECONFIG_PATH="${KUBECONFIG_PATH}" \
  bash -s <<'EOF'
set -o errexit
set -o pipefail
export KUBECONFIG="${KUBECONFIG_PATH}"
cd /tmp
./cleanup_external_frr_vrf.sh
EOF

# Sleep 10 seconds to ensure the bastion is ready
sleep 10

# Setup external FRR/VRF setup on bastion
ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${jumphost}" "root@${bastion}" env \
  KUBECONFIG_PATH="${KUBECONFIG_PATH}" \
  NUM_CUDN="${NUM_CUDN}" \
  EXTERNAL_WEBSERVER_IP="${EXTERNAL_WEBSERVER_IP}" \
  L3VNI_START="${L3VNI_START}" \
  L2VNI_START="${L2VNI_START}" \
  bash -s <<'EOF'
set -o errexit
set -o pipefail
export KUBECONFIG="${KUBECONFIG_PATH}"
cd /tmp
./setup_external_frr_vrf.sh "${NUM_CUDN}" "${EXTERNAL_WEBSERVER_IP}" "${L3VNI_START}" "${L2VNI_START}"
EOF

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

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

if [[ -n "${ITERATIONS}" ]]; then
  export ITERATIONS
else
  ITERATIONS=$(awk "BEGIN {printf \"%d\", int($ITERATION_MULTIPLIER * $current_worker_count)}")
  export ITERATIONS
fi

if [[ -n "${SCENARIO}" ]]; then
  EXTRA_FLAGS+=" --scenario=${SCENARIO}"
fi

EXTRA_FLAGS+=" --profile-type=${PROFILE_TYPE}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
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
