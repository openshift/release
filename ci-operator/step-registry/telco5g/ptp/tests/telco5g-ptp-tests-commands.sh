#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail

get_ci_images() {
  local release_image
  release_image="${RELEASE_IMAGE_LATEST:-}"
  if [[ -z "${release_image}" ]]; then
    release_image=$(oc get clusterversion version -o jsonpath='{.status.desired.image}')
  fi

  if [[ "${T5CI_DEPLOY_UPSTREAM:-false}" == "true" ]]; then
    export IMG="${PTP_OPERATOR_IMAGE:?PTP_OPERATOR_IMAGE not set by ci-operator dependency}"
    export DAEMON_IMG="${PTP_DAEMON_IMAGE:?PTP_DAEMON_IMAGE not set by ci-operator dependency}"
  else
    IMG=$(oc adm release info "${release_image}" --image-for=ptp-operator)
    export IMG
    DAEMON_IMG=$(oc adm release info "${release_image}" --image-for=ptp)
    export DAEMON_IMG
  fi

  if [[ "${T5CI_SIDECAR_FROM_CI:-false}" == "true" ]]; then
    export SIDECAR_IMG="${CLOUD_EVENT_PROXY_IMAGE:?CLOUD_EVENT_PROXY_IMAGE not set by ci-operator dependency}"
  else
    SIDECAR_IMG=$(oc adm release info "${release_image}" --image-for=cloud-event-proxy)
    export SIDECAR_IMG
  fi

  echo "[INFO] release_image=${release_image}"
  echo "[INFO] IMG=${IMG}"
  echo "[INFO] DAEMON_IMG=${DAEMON_IMG}"
  echo "[INFO] SIDECAR_IMG=${SIDECAR_IMG}"
}

retry_with_timeout() {
  local timeout=$1
  local interval=$2
  local command="${*:3}"
  echo command="$command"
  local start_time
  start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  while true; do
    ${command} && return 0
    local current_time
    current_time=$(date +%s)
    if [ "${current_time}" -gt "${end_time}" ]; then
      return 1
    fi
    sleep "${interval}"
  done
}

print_time() {
  NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  for node in $NODES; do
    echo "Processing node: $node"
    oc debug node/"$node" -- chroot /host sh -c "date;sudo hwclock"
  done
}

set_events_output_file() {
  sed -i -E 's@(event_output_file:\s*)(.*)@event_output_file: '"${ARTIFACT_DIR}"'/event_log_'"${PTP_TEST_MODE}"'.csv@g' "${SHARED_DIR}"/test-config.yaml
}

echo "************ telco5g cnf-tests commands ************"

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
  readarray -t config <<<"${E2E_TESTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ -n "${var}" ]]; then
      if [[ "${var}" == *"CNF_E2E_TESTS"* ]]; then
        CNF_E2E_TESTS="$(echo "${var}" | cut -d'=' -f2)"
      elif [[ "${var}" == *"CNF_ORIGIN_TESTS"* ]]; then
        CNF_ORIGIN_TESTS="$(echo "${var}" | cut -d'=' -f2)"
      fi
    fi
  done
fi

export CNF_E2E_TESTS
export CNF_ORIGIN_TESTS
export TEST_BRANCH="main"

if [[ "${T5CI_DEPLOY_UPSTREAM:-false}" == "true" ]]; then
  export PTP_UNDER_TEST_BRANCH="main"
else
  export PTP_UNDER_TEST_BRANCH="release-${T5CI_VERSION}"
fi

export KUBECONFIG=$SHARED_DIR/kubeconfig

echo "************ Checking node readiness ************"
oc get nodes -owide
NOT_READY_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -v "True$" || true)
if [[ -n "${NOT_READY_NODES}" ]]; then
  echo "[ERROR] The following nodes are not Ready:"
  echo "${NOT_READY_NODES}"
  echo "[ERROR] All nodes must be Ready before starting PTP tests. Aborting."
  exit 1
fi
TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
if [[ "${TOTAL_NODES}" -eq 0 ]]; then
  echo "[ERROR] No nodes found in the cluster. Aborting."
  exit 1
fi
echo "[INFO] All ${TOTAL_NODES} nodes are Ready."
echo "***************************************************"

temp_dir=$(mktemp -d -t cnf-XXXXX)
cd "$temp_dir" || exit 1

echo "deploying ptp-operator on branch ${PTP_UNDER_TEST_BRANCH}"

get_ci_images

if [[ "${T5CI_DEPLOY_UPSTREAM:-false}" == "true" ]]; then
  echo "Running on upstream main branch"
  git clone https://github.com/k8snetworkplumbingwg/ptp-operator.git -b "${PTP_UNDER_TEST_BRANCH}" ptp-operator-under-test
else
  git clone https://github.com/openshift/ptp-operator.git -b "${PTP_UNDER_TEST_BRANCH}" ptp-operator-under-test
fi

cd ptp-operator-under-test

grep -r "imagePullPolicy: IfNotPresent" --files-with-matches | awk '{print  "sed -i -e \"s@imagePullPolicy: IfNotPresent@imagePullPolicy: Always@g\" " $1 }' | bash

make deploy \
  IMG="${IMG}" \
  LINUXPTP_DAEMON_IMAGE="${DAEMON_IMG}" \
  SIDECAR_EVENT_IMAGE="${SIDECAR_IMG}"

retry_with_timeout 400 5 kubectl rollout status daemonset linuxptp-daemon -nopenshift-ptp

if [[ "$T5CI_VERSION" =~ 4.1[2-5]+ ]]; then
  export EVENT_API_VERSION="1.0"
  oc patch ptpoperatorconfigs.ptp.openshift.io default -nopenshift-ptp --patch '{"spec":{"ptpEventConfig":{"enableEventPublisher":true, "storageType":"emptyDir"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker":""}}}' --type=merge
else
  export EVENT_API_VERSION="2.0"
  oc patch ptpoperatorconfigs.ptp.openshift.io default -nopenshift-ptp --patch '{"spec":{"ptpEventConfig":{"enableEventPublisher":true, "apiVersion":"2.0"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker":""}}}' --type=merge
fi

if [[ "$T5CI_VERSION" =~ 4.1[6-7]+ ]]; then
  export ENABLE_V1_REGRESSION="true"
else
  export ENABLE_V1_REGRESSION="false"
fi

if [[ "$T5CI_VERSION" =~ 4.1[2-8]+ ]]; then
  echo "Version is less than 4.19"
  export CONSUMER_IMG="quay.io/redhat-cne/cloud-event-consumer:release-4.18"
  TEST_MODES=("dualnicbc" "dualnicbcha" "bc" "oc")

  if [[ "$T5CI_VERSION" =~ 4.1[2-5] ]]; then
    TEST_MODES=("${TEST_MODES[@]/dualnicbcha}")
  fi

  if [[ "$T5CI_VERSION" == 4.12 ]]; then
    TEST_MODES=("${TEST_MODES[@]/dualnicbc}")
  fi

else
  echo "Version is 4.19 or greater"
  export CONSUMER_IMG="quay.io/redhat-cne/cloud-event-consumer:latest"
  # Only run tgm and dualfollower tests from 4.19 onwards
  TEST_MODES=("tgm" "tbc" "dualfollower" "dualnicbc" "dualnicbcha" "bc" "oc")

  # T-BC test mode is only supported from 4.20 onwards,
  # so if the version is 4.19 then, remove it from the list
  if [[ "$T5CI_VERSION" == 4.19 ]]; then
    TEST_MODES=("${TEST_MODES[@]/tbc}")
  fi
fi

retry_with_timeout 400 5 kubectl rollout status daemonset linuxptp-daemon -nopenshift-ptp

cd -
echo "running conformance tests from branch ${TEST_BRANCH}"
git clone https://github.com/k8snetworkplumbingwg/ptp-operator.git -b "${TEST_BRANCH}" ptp-operator-conformance-test

cd ptp-operator-conformance-test

cat <<'EOF' >"${SHARED_DIR}"/test-config.yaml
---
global:
  maxoffset: 100
  minoffset: -100
soaktest:
  disable_all: false
  event_output_file: "./event-output.csv"
  duration: 10
  failure_threshold: 2
  master_offset:
    spec:
      enable: true
      duration: 10
      failure_threshold: 20
    desc: "This test measures the master offset check"
  slave_clock_sync:
    spec:
      enable: true
      duration: 5
      failure_threshold: 1
    desc: "The test measures number of PTP time sync faults, and fails if > failure_threshold"
  cpu_utilization:
    spec:
      enable: true
      duration: 5
      failure_threshold: 3
      custom_params:
        prometheus_rate_time_window: "70s"
        node:
          cpu_threshold_mcores: 100
        pod:
          - pod_type: "ptp-operator"
            cpu_threshold_mcores: 30

          - pod_type: "linuxptp-daemon"
            cpu_threshold_mcores: 80

          - pod_type: "linuxptp-daemon"
            container: "cloud-event-proxy"
            cpu_threshold_mcores: 30

          - pod_type: "linuxptp-daemon"
            container: "linuxptp-daemon-container"
            cpu_threshold_mcores: 40
    desc: "The test measures PTP CPU usage and fails if >15mcores"
EOF


export COLLECT_POD_LOGS=${COLLECT_POD_LOGS:-true}
export LOG_TEST_MARKERS=true
export LOG_ARTIFACTS_DIR="${ARTIFACT_DIR}/pod-logs"
mkdir -p $LOG_ARTIFACTS_DIR

export JUNIT_OUTPUT_DIR=${ARTIFACT_DIR}

export PTP_LOG_LEVEL=debug
export SKIP_INTERFACES=eno8303np0,eno8403np1,eno8503np2,eno8603np3,eno12409,eno8303,ens7f0np0,ens7f1np1,eno8403,ens6f0np0,ens6f1np1,eno8303np0,eno8403np1,eno8503np2,eno8603np3,eno12399
export PTP_TEST_CONFIG_FILE=${SHARED_DIR}/test-config.yaml

sleep 300

print_time

for mode in "${TEST_MODES[@]}"; do
  echo "Running tests for PTP_TEST_MODE=${mode}"

  export PTP_TEST_MODE="${mode}"
  export JUNIT_OUTPUT_FILE="test_results_${PTP_TEST_MODE}.xml"
  set_events_output_file

  temp_status="temp_status_${mode}"
  exit_code=0
  make functests || exit_code=$?
  declare "$temp_status=$exit_code"

  print_time
done

status=0
for mode in "${TEST_MODES[@]}"; do
  temp_status="temp_status_${mode}"
  if [[ -z ${!temp_status+x} ]]; then
    echo "Error: Variable $temp_status is unset!"
    status=1
    continue
  fi

  value="${!temp_status}"
  echo "$temp_status = $value"

  if [[ "$value" -ne 0 ]]; then
    status=1
    break
  fi
done

set +e

make undeploy

cd -

python3 -m venv "${SHARED_DIR}"/myenv
source "${SHARED_DIR}"/myenv/bin/activate
for attempt in $(seq 1 5); do
  git clone https://github.com/openshift-kni/telco5gci "${SHARED_DIR}"/telco5gci && break
  echo "WARNING: telco5gci clone attempt ${attempt}/5 failed"
  rm -rf "${SHARED_DIR}"/telco5gci
  [[ ${attempt} -lt 5 ]] && sleep 10
done
if [[ ! -d "${SHARED_DIR}"/telco5gci ]]; then
  echo "ERROR: Failed to clone telco5gci after 5 attempts"
  exit 1
fi
pip install -r "${SHARED_DIR}"/telco5gci/requirements.txt

python "${SHARED_DIR}"/telco5gci/j2html.py "${ARTIFACT_DIR}"/test_results_*xml -o "${ARTIFACT_DIR}"/test_results_all.html

for mode in "${TEST_MODES[@]}"; do
  python "${SHARED_DIR}"/telco5gci/j2html.py "${ARTIFACT_DIR}"/test_results_"${mode}".xml -o "${ARTIFACT_DIR}"/test_results_"${mode}".html
done

junitparser merge "${ARTIFACT_DIR}"/test_results_*xml "${ARTIFACT_DIR}"/test_results_all.xml &&
  cp "${ARTIFACT_DIR}"/test_results_all.xml "${ARTIFACT_DIR}"/junit.xml

python "${SHARED_DIR}"/telco5gci/junit2json.py "${ARTIFACT_DIR}"/test_results_all.xml -o "${ARTIFACT_DIR}"/test_results.json

rm -rf "$temp_dir"

set -e

exit "${status}"
