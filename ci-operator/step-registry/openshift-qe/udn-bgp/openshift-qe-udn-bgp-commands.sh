#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ ! -f "${SHARED_DIR}/frr-peer-address" ]]; then
  echo "ERROR: ${SHARED_DIR}/frr-peer-address not found; run openshift-qe-bgp-setup-udn-bgp first" >&2
  exit 1
fi
FRR_PEER_IP=$(tr -d '[:space:]' < "${SHARED_DIR}/frr-peer-address")
if [[ -z "${FRR_PEER_IP}" ]]; then
  echo "ERROR: ${SHARED_DIR}/frr-peer-address is empty" >&2
  exit 1
fi
echo "FRR peer address: ${FRR_PEER_IP}"

UUID=$(uuidgen)

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"

REPO_URL="${E2E_REPO:-https://github.com/cloud-bulldozer/e2e-benchmarking}"
LATEST_TAG=$(git ls-remote --tags "${REPO_URL}.git" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
if [ "${E2E_VERSION}" == "default" ]; then
  E2E_BRANCH="${LATEST_TAG}"
else
  E2E_BRANCH="${E2E_VERSION}"
fi

$WAS_TRACING && set -x

# Configure SSH to the external FRR bastion (AWS direct, BM via jumphost proxy).
if [[ -f "${SHARED_DIR}/bastion_ssh_key" ]]; then
  BASTION_SSH_KEY="/tmp/bastion_ssh_key"
  cp "${SHARED_DIR}/bastion_ssh_key" "${BASTION_SSH_KEY}"
  chmod 400 "${BASTION_SSH_KEY}"
  BASTION_HOST=$(cat "${SHARED_DIR}/bastion_public_address")
  BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user" 2>/dev/null || echo "root")
  SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null"
  BASTION_WORK_DIR="/root/udn-bgp"
  BASTION_KUBECONFIG_PATH=""
elif [[ -f "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key" ]]; then
  BASTION_SSH_KEY="${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
  JUMPHOST=$(cat "${CLUSTER_PROFILE_DIR}/address")
  BASTION_HOST=$(cat "${CLUSTER_PROFILE_DIR}/bastion" 2>/dev/null || cat "${SHARED_DIR}/bastion")
  BASTION_SSH_USER="root"
  SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  BASTION_WORK_DIR="/tmp"
  TYPE=${TYPE:-mno}
  if [[ "${TYPE}" == "hmno" ]]; then
    BASTION_KUBECONFIG_PATH="/root/mno/kubeconfig"
  else
    BASTION_KUBECONFIG_PATH="/root/${TYPE}/kubeconfig"
  fi
else
  echo "ERROR: No bastion SSH credentials found" >&2
  exit 1
fi

ICMP_CAPTURE_DIR="${BASTION_WORK_DIR}/icmp-pcaps"

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

echo "=== Run UDN-BGP kube-burner from bastion ==="

# ssh concatenates remote argv without quoting, so values with spaces
# (EXTRA_FLAGS) never arrive intact. Pass space-free vars and rebuild flags
# on the bastion. PROW vars are required for utils/index.sh metadata indexing.
BASTION_ENV=( \
  BASTION_KUBECONFIG_PATH="${BASTION_KUBECONFIG_PATH}" \
  BASTION_WORK_DIR="${BASTION_WORK_DIR}" \
  BUILD_ID="${BUILD_ID:-}" \
  E2E_BRANCH="${E2E_BRANCH}" \
  E2E_REPO="${REPO_URL}" \
  ENABLE_LOCAL_INDEX="${ENABLE_LOCAL_INDEX}" \
  ES_METADATA_INDEX="${ES_METADATA_INDEX:-perf_scale_ci}" \
  ES_SERVER="${ES_SERVER}" \
  FRR_PEER_IP="${FRR_PEER_IP}" \
  GC="${GC}" \
  ICMP_CAPTURE_DIR="${ICMP_CAPTURE_DIR}" \
  ICMP_CAPTURE_FILTER="${ICMP_CAPTURE_FILTER:-icmp}" \
  ITERATIONS="${ITERATIONS}" \
  JOB_NAME="${JOB_NAME:-}" \
  JOB_TYPE="${JOB_TYPE:-}" \
  KUBE_BURNER_VERSION="${KUBE_BURNER_VERSION}" \
  KUBE_BURNER_OCP_REF="${KUBE_BURNER_OCP_REF}" \
  KUBE_BURNER_OCP_REPO="${KUBE_BURNER_OCP_REPO}" \
  PROFILE_TYPE="${PROFILE_TYPE}" \
  PROW_JOB_ID="${PROW_JOB_ID:-}" \
  PULL_NUMBER="${PULL_NUMBER:-0}" \
  PPROF="${PPROF:-false}" \
  PPROF_INTERVAL="${PPROF_INTERVAL:-0}" \
  REPO_NAME="${REPO_NAME:-}" \
  REPO_OWNER="${REPO_OWNER:-}" \
  REPO_URL="${REPO_URL}" \
  UDN_BGP_LAYER2="${UDN_BGP_LAYER2:-true}" \
  UUID="${UUID}" \
)

set +o errexit
set +x
bastion_ssh env "${BASTION_ENV[@]}" bash -s <<'EOF'
set -o errexit
set -o pipefail

if [[ -n "${BASTION_KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${BASTION_KUBECONFIG_PATH}"
fi

mkdir -p "${BASTION_WORK_DIR}"
cd "${BASTION_WORK_DIR}"
rm -rf e2e-benchmarking
git clone "${REPO_URL}" --branch "${E2E_BRANCH}" --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

for node in $(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}'); do
  echo "Pre-loading image on node ${node}..."
  oc debug "node/${node}" -n default -- chroot /host crictl pull quay.io/cloud-bulldozer/sampleapp:latest
done

rm -rf "${ICMP_CAPTURE_DIR}"
mkdir -p "${ICMP_CAPTURE_DIR}"
ICMP_CAPTURE_FAILED=0

collect_icmp_diagnostics() {
  local diagnostics_dir="${ICMP_CAPTURE_DIR}/diagnostics"
  mkdir -p "${diagnostics_dir}"

  oc get namespace udn-bgp-icmp-capture -o yaml \
    > "${diagnostics_dir}/namespace.yaml"
  oc describe daemonset icmp-capture -n udn-bgp-icmp-capture \
    > "${diagnostics_dir}/daemonset.txt"
  oc get pods -n udn-bgp-icmp-capture -l app=icmp-capture -o wide \
    > "${diagnostics_dir}/pods.txt"
  oc get events -n udn-bgp-icmp-capture --sort-by=.lastTimestamp \
    > "${diagnostics_dir}/events.txt"

  while read -r pod; do
    oc describe "${pod}" -n udn-bgp-icmp-capture \
      >> "${diagnostics_dir}/pods-described.txt"
    oc logs -n udn-bgp-icmp-capture "${pod}" \
      > "${diagnostics_dir}/${pod##*/}.log" 2>&1 || true
    oc logs -n udn-bgp-icmp-capture "${pod}" --previous \
      > "${diagnostics_dir}/${pod##*/}-previous.log" 2>&1 || true
  done < <(oc get pods -n udn-bgp-icmp-capture -l app=icmp-capture -o name)
}

cleanup_icmp_capture() {
  local exit_code=$?
  set +o errexit

  if oc get namespace udn-bgp-icmp-capture > /dev/null 2>&1; then
    collect_icmp_diagnostics
  fi

  for pod in $(oc get pods -n udn-bgp-icmp-capture -l app=icmp-capture -o name); do
    oc exec -n udn-bgp-icmp-capture "${pod}" -- \
      pkill -INT -x tcpdump || true
  done
  sleep 3

  while read -r pod node; do
    if ! oc exec -n udn-bgp-icmp-capture "${pod}" -- \
      tar -czf - -C /captures . \
      > "${ICMP_CAPTURE_DIR}/${node}.tar.gz"; then
      echo "ERROR: Failed to collect ICMP capture from ${node}" >&2
      ICMP_CAPTURE_FAILED=1
    fi
  done < <(oc get pods -n udn-bgp-icmp-capture -l app=icmp-capture \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

  oc delete namespace udn-bgp-icmp-capture --ignore-not-found=true --wait=false

  if [[ "${ICMP_CAPTURE_FAILED}" -ne 0 && "${exit_code}" -eq 0 ]]; then
    exit_code=1
  fi
  exit "${exit_code}"
}
trap cleanup_icmp_capture EXIT

echo "=== Deploying node ICMP capture probes ==="
cat <<'YAML' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: udn-bgp-icmp-capture
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: icmp-capture
  namespace: udn-bgp-icmp-capture
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: icmp-capture
  namespace: udn-bgp-icmp-capture
spec:
  selector:
    matchLabels:
      app: icmp-capture
  template:
    metadata:
      labels:
        app: icmp-capture
    spec:
      serviceAccountName: icmp-capture
      hostNetwork: true
      tolerations:
      - operator: Exists
      terminationGracePeriodSeconds: 30
      containers:
      - name: tcpdump
        image: image-registry.openshift-image-registry.svc:5000/openshift/tools:latest
        command: ["/bin/bash", "-ceu"]
        args:
        - |
          iface=$(ip -o -4 route show default | awk '{print $5; exit}')
          if [[ -z "${iface}" ]]; then
            echo "ERROR: No default IPv4 route found" >&2
            exit 1
          fi
          echo "Capturing ICMP on ${NODE_NAME} interface ${iface}"
          tcpdump -i "${iface}" -nn -s 256 -Z root -W 4 -C 10 \
            -w "/captures/${NODE_NAME}-${iface}.pcap" \
            "${TCPDUMP_FILTER}" &
          tcpdump_pid=$!
          trap 'kill -INT "${tcpdump_pid}" 2>/dev/null || true; wait "${tcpdump_pid}" || true' TERM INT
          wait "${tcpdump_pid}"
          sleep infinity
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: TCPDUMP_FILTER
          value: icmp
        readinessProbe:
          exec:
            command:
            - /bin/bash
            - -c
            - pgrep -x tcpdump
          initialDelaySeconds: 2
          periodSeconds: 2
          failureThreshold: 3
        securityContext:
          privileged: true
          runAsUser: 0
        resources:
          requests:
            cpu: 10m
            memory: 50Mi
        volumeMounts:
        - name: captures
          mountPath: /captures
      volumes:
      - name: captures
        hostPath:
          path: /var/tmp/udn-bgp-icmp
          type: DirectoryOrCreate
YAML
oc adm policy add-scc-to-user privileged -z icmp-capture -n udn-bgp-icmp-capture
oc set env -n udn-bgp-icmp-capture ds/icmp-capture "TCPDUMP_FILTER=${ICMP_CAPTURE_FILTER}"
oc rollout status daemonset/icmp-capture -n udn-bgp-icmp-capture --timeout=2m

EXTRA_FLAGS=""
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
  EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=false --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --frr-external-ip=${FRR_PEER_IP}"
EXTRA_FLAGS+=" --log-level=debug"
EXTRA_FLAGS+=" --pprof=${PPROF}"
if [[ "${PPROF_INTERVAL}" != "0" ]]; then
  EXTRA_FLAGS+=" --pprof-interval=${PPROF_INTERVAL}"
fi
if [[ "${UDN_BGP_LAYER2}" == "true" ]]; then
  EXTRA_FLAGS+=" --layer2"
fi

export WORKLOAD=udn-bgp
export ES_SERVER ES_METADATA_INDEX EXTRA_FLAGS GC ITERATIONS KUBE_BURNER_VERSION UUID
export PROW_JOB_ID BUILD_ID JOB_NAME JOB_TYPE PULL_NUMBER REPO_OWNER REPO_NAME
set +o errexit
./run.sh
WORKLOAD_EXIT_CODE=$?
set -o errexit
exit "${WORKLOAD_EXIT_CODE}"
EOF
RUN_EXIT_CODE=$?
$WAS_TRACING && set -x
set -o errexit

METRICS_FOLDER="${BASTION_WORK_DIR}/e2e-benchmarking/workloads/kube-burner-ocp-wrapper/collected-metrics-${UUID}"
if bastion_ssh "test -f ${METRICS_FOLDER}/jobSummary.json"; then
  bastion_scp -r "${BASTION_SSH_USER}@${BASTION_HOST}:${METRICS_FOLDER}" "${ARTIFACT_DIR}/"
fi

PPROF_FOLDER="${BASTION_WORK_DIR}/e2e-benchmarking/workloads/kube-burner-ocp-wrapper/pprof-data"
if [[ "${PPROF}" == "true" ]]; then
  if bastion_ssh "test -d ${PPROF_FOLDER}"; then
    bastion_scp -r "${BASTION_SSH_USER}@${BASTION_HOST}:${PPROF_FOLDER}" "${ARTIFACT_DIR}/"
    if [[ -z "$(find "${ARTIFACT_DIR}/pprof-data" -type f -name '*.pprof' -print -quit)" ]]; then
      echo "ERROR: pprof was enabled but no pprof files were collected" >&2
      RUN_EXIT_CODE=1
    fi
  else
    echo "ERROR: pprof was enabled but ${PPROF_FOLDER} was not created" >&2
    RUN_EXIT_CODE=1
  fi
fi

if bastion_ssh "test -d ${ICMP_CAPTURE_DIR}"; then
  bastion_scp -r "${BASTION_SSH_USER}@${BASTION_HOST}:${ICMP_CAPTURE_DIR}" "${ARTIFACT_DIR}/"
else
  echo "ERROR: ICMP capture directory was not created on the bastion" >&2
  RUN_EXIT_CODE=1
fi

exit ${RUN_EXIT_CODE}
