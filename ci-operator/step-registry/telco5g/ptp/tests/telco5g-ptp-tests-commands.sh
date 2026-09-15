#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail

# ===========================================================================
# CONFIGURATION
# Override any of these environment variables to customize the CI run.
# All have sensible defaults — no changes needed for standard nightly CI.
# ===========================================================================

# --- OCP version under test ---
# In CI this is set by the job definition. For local/manual runs, set it
# to the release you are testing against (e.g. "4.22", "5.0").
export T5CI_VERSION="${T5CI_VERSION:-5.0}"

# --- Source repos and branches ---
# Test code: repo and branch for the conformance test suite
export TEST_REPO="${TEST_REPO:-https://github.com/edcdavid/ptp-operator-upstream.git}"
export TEST_BRANCH="${TEST_BRANCH:-tbc-software-gm}"

# Product under test: repo and branch for the operator being deployed
if [[ "${T5CI_DEPLOY_UPSTREAM:-false}" == "true" ]]; then
  export PTP_REPO="${PTP_REPO:-https://github.com/k8snetworkplumbingwg/ptp-operator.git}"
  export PTP_UNDER_TEST_BRANCH="${PTP_UNDER_TEST_BRANCH:-main}"
  export DAEMON_REPO="${DAEMON_REPO:-https://github.com/k8snetworkplumbingwg/linuxptp-daemon.git}"
  export CEP_REPO="${CEP_REPO:-https://github.com/redhat-cne/cloud-event-proxy.git}"
else
  export PTP_REPO="${PTP_REPO:-https://github.com/openshift/ptp-operator.git}"
  export PTP_UNDER_TEST_BRANCH="${PTP_UNDER_TEST_BRANCH:-release-${T5CI_VERSION}}"
fi

# --- Test settings ---
export PTP_LOG_LEVEL="${PTP_LOG_LEVEL:-debug}"
export SKIP_INTERFACES="${SKIP_INTERFACES:-eno8303np0,eno8403np1,eno8503np2,eno8603np3,eno12409,eno8303,eno8403,ens6f0np0,ens6f1np1,eno8303np0,eno8403np1,eno8503np2,eno8603np3,eno12399}"
export COLLECT_POD_LOGS="${COLLECT_POD_LOGS:-true}"

# --- Event API, consumer image, and test modes (version-dependent) ---
# Event API and feature flags by release:
#   Release  | EVENT_API_VERSION | ENABLE_V1_REGRESSION | Consumer image
#   ---------+-------------------+----------------------+--------------------------
#   4.12-4.15| 1.0               | false                | cloud-event-consumer:release-4.18
#   4.16-4.17| 2.0               | true                 | cloud-event-consumer:release-4.18
#   4.18     | 2.0               | false                | cloud-event-consumer:release-4.18
#   4.19+    | 2.0               | false                | cloud-event-consumer:latest
if [[ "$T5CI_VERSION" =~ 4.1[2-5]+ ]]; then
  export EVENT_API_VERSION="1.0"
else
  export EVENT_API_VERSION="2.0"
fi

if [[ "$T5CI_VERSION" =~ 4.1[6-7]+ ]]; then
  export ENABLE_V1_REGRESSION="true"
else
  export ENABLE_V1_REGRESSION="false"
fi

# Test modes by release:
#   Release  | oc | bc | dualnicbc | dualnicbcha | dualfollower | tbc | tgm
#   ---------+----+----+-----------+-------------+--------------+-----+----
#   4.12     | Y  | Y  |           |             |              |     |
#   4.13-4.15| Y  | Y  | Y         |             |              |     |
#   4.16-4.18| Y  | Y  | Y         | Y           |              |     |
#   4.19     | Y  | Y  | Y         | Y           | Y            |     | Y
#   4.20+    | Y  | Y  | Y         | Y           | Y            | Y   | Y
if [[ "$T5CI_VERSION" == 4.12 ]]; then
  export CONSUMER_IMG="${CONSUMER_IMG:-quay.io/redhat-cne/cloud-event-consumer:release-4.18}"
  TEST_MODES=("bc" "oc")
elif [[ "$T5CI_VERSION" =~ 4.1[3-5] ]]; then
  export CONSUMER_IMG="${CONSUMER_IMG:-quay.io/redhat-cne/cloud-event-consumer:release-4.18}"
  TEST_MODES=("dualnicbc" "bc" "oc")
elif [[ "$T5CI_VERSION" =~ 4.1[6-8] ]]; then
  export CONSUMER_IMG="${CONSUMER_IMG:-quay.io/redhat-cne/cloud-event-consumer:release-4.18}"
  TEST_MODES=("dualnicbc" "dualnicbcha" "bc" "oc")
elif [[ "$T5CI_VERSION" == 4.19 ]]; then
  export CONSUMER_IMG="${CONSUMER_IMG:-quay.io/redhat-cne/cloud-event-consumer:latest}"
  TEST_MODES=("tgm" "dualfollower" "dualnicbc" "dualnicbcha" "bc" "oc")
else
  # 4.20+
  export CONSUMER_IMG="${CONSUMER_IMG:-quay.io/redhat-cne/cloud-event-consumer:latest}"
  TEST_MODES=("tgm" "tbc" "dualfollower" "dualnicbc" "dualnicbcha" "bc" "oc")
fi

# ===========================================================================

# ---------------------------------------------------------------------------
# Build script that runs inside the podman builder pod.
# Clones, builds, and pushes PTP operator / daemon / sidecar images.
# Placeholder tokens (PTP_IMAGE, OPERATOR_VERSION, etc.) are substituted
# by build_pod_definition() before the pod is created.
# ---------------------------------------------------------------------------
build_script() {
  cat <<'BUILDSCRIPT'
set -xe
yum install jq git wget podman-docker -y
yum group install "development-tools" -y
wget https://go.dev/dl/go1.20.4.linux-amd64.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.20.4.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
go version

# set +x here to hide pass from log
set +xe

echo "podman login with serviceaccount"

# Used for 4.16 and newer releases.
pass=$( jq .\"image-registry.openshift-image-registry.svc:5000\".auth /var/run/secrets/openshift.io/push/.dockercfg )
pass=`echo ${pass:1:-1} | base64 -d`
podman login -u serviceaccount -p ${pass:8} image-registry.openshift-image-registry.svc:5000 --tls-verify=false

# Used for 4.15 and older releases.
if ! podman login --get-login image-registry.openshift-image-registry.svc:5000 &> /dev/null; then
  pass=$( jq .\"image-registry.openshift-image-registry.svc:5000\".password /var/run/secrets/openshift.io/push/.dockercfg )
  podman login -u serviceaccount -p ${pass:1:-1} image-registry.openshift-image-registry.svc:5000 --tls-verify=false
fi

set -x

export IMG=PTP_IMAGE
export DAEMON_IMG="DAEMON_IMAGE"
export SIDECAR_IMG="SIDECAR_IMAGE"

export T5CI_VERSION="T5CI_VERSION_VAL"
export USE_UPSTREAM="USE_UPSTREAM_VAL"

# run latest release on upstream main branch
if [[ "${USE_UPSTREAM:-false}" == "true" ]]; then
  echo "Running on upstream main branch"
  git clone --single-branch --branch main PTP_REPO_URL
else
  git clone --single-branch --branch OPERATOR_VERSION PTP_REPO_URL
fi
cd ptp-operator
# OCPBUGS-52327 fix build due to libresolv.so link error
sed -i "s/\(CGO_ENABLED=\${CGO_ENABLED}\) \(GOOS=\${GOOS}\)/\1 CC=\"gcc -fuse-ld=gold\" \2/" hack/build.sh
# For UPSTREAM use Dockerfile for upstream contents
if [[ "$T5CI_VERSION" =~ 4.1[2-8]+ || "${USE_UPSTREAM:-false}" == "true" ]]; then
  sed -i "/ENV GO111MODULE=off/ a\ENV GOMAXPROCS=20" Dockerfile
  make docker-build
else
  # Dockerfile is updated to upstream in 4.19+. Use .ocp or .ci versions for non-UPSTREAM runs
  if [ -f "Dockerfile.ocp" ]; then
    DOCKERFILE="Dockerfile.ocp"
  else
    DOCKERFILE="Dockerfile.ci"
  fi
  sed -i "/ENV GO111MODULE=off/ a\ENV GOMAXPROCS=20" "$DOCKERFILE"
  podman build -t "${IMG}" -f "$DOCKERFILE"
fi
podman push ${IMG} --tls-verify=false
cd ..

if [[ "${USE_UPSTREAM:-false}" == "false" ]]; then
  # If we a running a downstream run we are done
  exit 0
fi

# If were running upstream we should also use the upstream daemon!
echo "Running on upstream main branch of linuxptp-daemon"
git clone --single-branch --branch main DAEMON_REPO_URL
cd linuxptp-daemon
# Split DAEMON_IMG into IMAGE_TAG_BASE and VERSION because
# hack/build-image.sh unconditionally overwrites IMG from these two vars.
IMAGE_TAG_BASE="${DAEMON_IMG%:*}" VERSION="${DAEMON_IMG##*:}" make image
podman push ${DAEMON_IMG} --tls-verify=false
cd ..

echo "Running on main branch of cloud-event-proxy"
git clone --single-branch --branch main CEP_REPO_URL
cd cloud-event-proxy
IMG=${SIDECAR_IMG} make podman-build
podman push ${SIDECAR_IMG} --tls-verify=false
cd ..
BUILDSCRIPT
}

# ---------------------------------------------------------------------------
# Assemble the RBAC + Pod YAML for the builder pod.
# Substitutes all placeholder tokens and returns the final manifest on stdout.
# Requires: dockercfg_secret (name of the builder-dockercfg-* secret)
# ---------------------------------------------------------------------------
build_pod_definition() {
  local dockercfg_secret=$1
  local script
  script=$(build_script)

  # Indent the build script to fit inside the YAML command block (10 spaces)
  local indented_script
  indented_script=$(echo "$script" | sed 's/^/          /')

  cat <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: privileged-rights
  namespace: openshift-ptp
rules:
- apiGroups:
  - security.openshift.io
  resourceNames:
  - privileged
  resources:
  - securitycontextconstraints
  verbs:
  - use
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  managedFields:
  name: privileged-rights
  namespace: openshift-ptp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: privileged-rights
subjects:
- kind: ServiceAccount
  name: builder
  namespace: openshift-ptp
---
apiVersion: v1
kind: Pod
metadata:
  name: podman
  namespace: openshift-ptp
spec:
  restartPolicy: Never
  serviceAccountName: builder
  containers:
    - name: priv
      image: quay.io/podman/stable:v4.9.4
      command:
        - /bin/bash
        - -c
        - |
${indented_script}
      securityContext:
        privileged: true
      volumeMounts:
        - mountPath: /var/run/secrets/openshift.io/push
          name: dockercfg
          readOnly: true
        - name: secret-volume
          mountPath: /root/.docker
  volumes:
    - name: secret-volume
      secret:
        secretName: pull-secret
        items:
        - key: .dockerconfigjson
          path: config.json
    - name: dockercfg
      secret:
        secretName: ${dockercfg_secret}
        defaultMode: 384
EOF
}

# ---------------------------------------------------------------------------
# Build PTP images: create namespace, RBAC, builder pod, wait for completion.
# ---------------------------------------------------------------------------
build_images() {
  oc delete namespace openshift-ptp || true
  oc create namespace openshift-ptp -o yaml | oc label -f - \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged || true
  oc get secret pull-secret --namespace=openshift-config -oyaml \
    | grep -v '^\s*namespace:\s' | oc apply --namespace=openshift-ptp -f -
  echo "$KUBECONFIG"

  retry_with_timeout 400 5 oc -n openshift-ptp get sa builder

  # Wait for builder-dockercfg secret
  local dockercgf=""
  for i in $(seq 1 80); do
    dockercgf=$(oc --request-timeout=10s -n openshift-ptp get secret \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | grep '^builder-dockercfg-' | head -1 || true)
    if [[ -n "${dockercgf}" ]]; then
      break
    fi
    echo "Waiting for builder-dockercfg secret (attempt ${i}/80)..."
    sleep 5
  done
  if [[ -z "${dockercgf}" ]]; then
    echo "[ERROR] builder-dockercfg secret not found after 400s"
    exit 1
  fi

  # Generate pod definition with all tokens substituted
  local jobdefinition
  jobdefinition=$(build_pod_definition "${dockercgf}")
  jobdefinition=$(sed "s#OPERATOR_VERSION#${PTP_UNDER_TEST_BRANCH}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#PTP_REPO_URL#${PTP_REPO}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#DAEMON_REPO_URL#${DAEMON_REPO:-}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#CEP_REPO_URL#${CEP_REPO:-}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#PTP_IMAGE#${IMG}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#DAEMON_IMAGE#${DAEMON_IMG}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#SIDECAR_IMAGE#${SIDECAR_IMG}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#T5CI_VERSION_VAL#${T5CI_VERSION}#" <<<"$jobdefinition")
  jobdefinition=$(sed "s#USE_UPSTREAM_VAL#${T5CI_DEPLOY_UPSTREAM:-false}#" <<<"$jobdefinition")

  echo "$jobdefinition"
  echo "$jobdefinition" | oc apply -f -

  # Wait for builder pod to complete
  local success=0 iterations=0 sleep_time=10 max_iterations=120
  until [[ $success -eq 1 ]] || [[ $iterations -eq $max_iterations ]]; do
    run_status=$(oc -n openshift-ptp get pod podman -o json | jq '.status.phase' | tr -d '"')
    if [ "$run_status" == "Succeeded" ]; then
      success=1
      break
    elif [ "$run_status" == "Failed" ]; then
      echo "[ERROR] builder pod failed at iteration ${iterations}"
      break
    fi
    iterations=$((iterations + 1))
    sleep $sleep_time
  done

  echo "[INFO] --- builder pod logs ---"
  oc -n openshift-ptp logs podman
  echo "[INFO] --- end builder pod logs ---"

  if [[ $success -eq 1 ]]; then
    echo "[INFO] index build succeeded"
  else
    echo "[ERROR] index build failed (status: ${run_status})"
    exit 1
  fi
}

# Define the function to retry a command with a timeout
retry_with_timeout() {
  local timeout=$1
  local interval=$2
  local command="${*:3}"
  echo command="$command"
  local start_time
  start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  while true; do
    # Run the command
    ${command} && return 0

    # Check if the timeout has expired
    local current_time
    current_time=$(date +%s)
    if [ "${current_time}" -gt "${end_time}" ]; then
      return 1
    fi

    # Sleep for the specified interval before retrying
    sleep "${interval}"
  done
}

# print RTC logs
print_time() {
  # Get the list of nodes in the cluster
  NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  # Loop through each node
  for node in $NODES; do
    echo "Processing node: $node"
    oc debug node/"$node" -- chroot /host sh -c "date;sudo hwclock"
  done
}

set_events_output_file() {
  sed -i -E 's@(event_output_file:\s*)(.*)@event_output_file: '"${ARTIFACT_DIR}"'/event_log_'"${PTP_TEST_MODE}"'.csv@g' "${SHARED_DIR}"/test-config.yaml
}

# ---------------------------------------------------------------------------
# Parse E2E test config overrides
# ---------------------------------------------------------------------------
echo "************ telco5g cnf-tests commands ************"
echo "[INFO] ===== Step: Parse E2E test config overrides ====="

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
export IMG_VERSION="release-${T5CI_VERSION}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
export KUBECONFIG=$SHARED_DIR/kubeconfig

echo "[INFO] ===== Step: Pre-flight checks ====="
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

# ---------------------------------------------------------------------------
# Build and deploy PTP operator
# ---------------------------------------------------------------------------
echo "[INFO] ===== Step: Build and deploy PTP operator ====="
echo "[INFO] T5CI_VERSION=${T5CI_VERSION} PTP_REPO=${PTP_REPO} PTP_UNDER_TEST_BRANCH=${PTP_UNDER_TEST_BRANCH}"
echo "[INFO] DEPLOY_UPSTREAM=${T5CI_DEPLOY_UPSTREAM:-false} EVENT_API=${EVENT_API_VERSION} TEST_MODES=${TEST_MODES[*]}"

if [[ "$T5CI_VERSION" =~ 4.1[2-5]+ ]]; then
  source "$HOME"/golang-1.20
else
  source "$HOME"/golang-1.22.4
fi

temp_dir=$(mktemp -d -t cnf-XXXXX)
cd "$temp_dir" || exit 1

# deploy ptp
echo "deploying ptp-operator on branch ${PTP_UNDER_TEST_BRANCH}"

# build ptp operator and create catalog

export REGISTRY="image-registry.openshift-image-registry.svc:5000"
export IMG="${REGISTRY}/openshift-ptp/ptp-operator:${T5CI_VERSION}"
export DAEMON_IMG="${REGISTRY}/openshift-ptp/linuxptp-daemon:${T5CI_VERSION}"
export SIDECAR_IMG="${REGISTRY}/openshift-ptp/cloud-event-proxy:${T5CI_VERSION}"
echo "[INFO] --- Building PTP images via builder pod ---"
build_images
echo "[INFO] --- Build complete ---"

echo "[INFO] --- Downloading latest oc client ---"
mkdir ~/bin
wget https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar -zxvf openshift-client-linux.tar.gz -C ~/bin
export PATH=$HOME/bin:$PATH

oc version --client

echo "[INFO] --- Deploying PTP operator ---"
echo "Cloning ptp-operator from ${PTP_REPO} branch ${PTP_UNDER_TEST_BRANCH}"
git clone "${PTP_REPO}" -b "${PTP_UNDER_TEST_BRANCH}" ptp-operator-under-test

cd ptp-operator-under-test

# force downloading fresh images
grep -r "imagePullPolicy: IfNotPresent" --files-with-matches | awk '{print  "sed -i -e \"s@imagePullPolicy: IfNotPresent@imagePullPolicy: Always@g\" " $1 }' | bash

# deploy ptp-operator
if [[ "${T5CI_DEPLOY_UPSTREAM:-false}" == "true" ]]; then
  make deploy \
    IMG=${IMG} \
    LINUXPTP_DAEMON_IMAGE=${DAEMON_IMG} \
    SIDECAR_EVENT_IMAGE=${SIDECAR_IMG}
else
  make deploy IMG=${IMG}
fi

# wait until the linuxptp-daemon pods are ready
retry_with_timeout 400 5 kubectl rollout status daemonset linuxptp-daemon -nopenshift-ptp

# ---------------------------------------------------------------------------
# Enable PTP events on the cluster
# ---------------------------------------------------------------------------
echo "[INFO] ===== Step: Enable PTP events (API ${EVENT_API_VERSION}) ====="
if [[ "$EVENT_API_VERSION" == "1.0" ]]; then
  oc patch ptpoperatorconfigs.ptp.openshift.io default -nopenshift-ptp --patch '{"spec":{"ptpEventConfig":{"enableEventPublisher":true, "storageType":"emptyDir"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker":""}}}' --type=merge
else
  oc patch ptpoperatorconfigs.ptp.openshift.io default -nopenshift-ptp --patch '{"spec":{"ptpEventConfig":{"enableEventPublisher":true, "apiVersion":"'"${EVENT_API_VERSION}"'"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker":""}}}' --type=merge
fi

retry_with_timeout 400 5 kubectl rollout status daemonset linuxptp-daemon -nopenshift-ptp

# ---------------------------------------------------------------------------
# Clone test code and run conformance tests
# ---------------------------------------------------------------------------
echo "[INFO] ===== Step: Clone test code and run conformance tests ====="
cd -
echo "running conformance tests from ${TEST_REPO} branch ${TEST_BRANCH}"
git clone "${TEST_REPO}" -b "${TEST_BRANCH}" ptp-operator-conformance-test

cd ptp-operator-conformance-test

# configuration
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


# --- Log collection and output directories ---
export LOG_TEST_MARKERS=true
export LOG_ARTIFACTS_DIR="${ARTIFACT_DIR}/pod-logs"
mkdir -p "$LOG_ARTIFACTS_DIR"
export JUNIT_OUTPUT_DIR=${ARTIFACT_DIR}
export PTP_TEST_CONFIG_FILE=${SHARED_DIR}/test-config.yaml

# ---------------------------------------------------------------------------
# Run test suites for each mode
# ---------------------------------------------------------------------------
echo "[INFO] --- Waiting 300s for OpenShift to complete initialization ---"
sleep 300

print_time  # RTC logs

echo "[INFO] ===== Step: Run test suites ====="
for mode in "${TEST_MODES[@]}"; do
  echo "[INFO] --- Running tests for PTP_TEST_MODE=${mode} ---"

  export PTP_TEST_MODE="${mode}"
  export JUNIT_OUTPUT_FILE="test_results_${PTP_TEST_MODE}.xml"
  set_events_output_file

  temp_status="temp_status_${mode}" # Convert to lowercase for variable naming
  exit_code=0
  make functests || exit_code=$?
  declare "$temp_status=$exit_code"

  # Get RTC logs
  print_time
done

# ---------------------------------------------------------------------------
# Collect results and determine exit status
# ---------------------------------------------------------------------------
echo "[INFO] ===== Step: Collect results ====="
status=0
for mode in "${TEST_MODES[@]}"; do
  temp_status="temp_status_${mode}"
  # If the variable is not set return an error
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

# ---------------------------------------------------------------------------
# Cleanup and publish results
# ---------------------------------------------------------------------------
echo "[INFO] ===== Step: Cleanup and publish results ====="
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

# Create HTML reports for humans/aliens
python "${SHARED_DIR}"/telco5gci/j2html.py "${ARTIFACT_DIR}"/test_results_*xml -o "${ARTIFACT_DIR}"/test_results_all.html

for mode in "${TEST_MODES[@]}"; do
  python "${SHARED_DIR}"/telco5gci/j2html.py "${ARTIFACT_DIR}"/test_results_"${mode}".xml -o "${ARTIFACT_DIR}"/test_results_"${mode}".html
done

# merge junit files in to one
junitparser merge "${ARTIFACT_DIR}"/test_results_*xml "${ARTIFACT_DIR}"/test_results_all.xml &&
  cp "${ARTIFACT_DIR}"/test_results_all.xml "${ARTIFACT_DIR}"/junit.xml

# Create JSON reports for robots
python "${SHARED_DIR}"/telco5gci/junit2json.py "${ARTIFACT_DIR}"/test_results_all.xml -o "${ARTIFACT_DIR}"/test_results.json

# delete temp directory
rm -rf "$temp_dir"

# cancel "allows commands to fail without returning"
set -e

# return saved status
echo "[INFO] ===== Done (exit ${status}) ====="
exit "${status}"
