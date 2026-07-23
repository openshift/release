#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            echo "Mapping Test Suite Name To: OADP-lp-interop"
            yq eval -px -ox -iI0 '.testsuites.testsuite."+@name" = "OADP-lp-interop"' $results_file || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}

function collect-results() {
    if [[ $MAP_TESTS == "true" ]]; then
      install_yq_if_not_exists
      original_results="${ARTIFACT_DIR}/original_results/"
      mkdir -p "${original_results}"
      echo "Collecting original results in ${original_results}"

      # Keep a copy of all the original Junit files before modifying them
      cp -r "${ARTIFACT_DIR}"/junit_* "${original_results}" || echo "Warning: couldn't copy original files" >&2

      find "${ARTIFACT_DIR}" -type f -iname "*.xml" | while IFS= read -r result_file; do
        # Map tests if needed for related use cases
        mapTestsForComponentReadiness "${result_file}"
        # Send modified files to shared dir for Data Router Reporter step
        cp "${result_file}" "${SHARED_DIR}" || echo "Warning: couldn't copy ${result_file} to SHARED_DIR" >&2
      done
    fi
}

# Post test execution
trap 'collect-results' SIGINT SIGTERM ERR EXIT

# Set variables needed for test execution
export PROVIDER=$OADP_CLOUD_PROVIDER
export REGION=${REGION:-"us-east-2"}
export BACKUP_LOCATION=$OADP_BACKUP_LOCATION
export PROW_NAMESPACE=$NAMESPACE
export NAMESPACE="openshift-adp"
export BUCKET="${PROW_NAMESPACE}-${BUCKET_NAME}"
export KUBECONFIG="/home/jenkins/.kube/config"
export OADP_TEST_FOCUS="--focus=${OADP_TEST_FOCUS}"
export TEMP_TEST_FOCUS=$OADP_TEST_FOCUS
export ANSIBLE_REMOTE_TMP="/tmp/"
# STORAGE_CLASS will be configured later based on cluster state
# Initialize EXTRA_GINKGO_PARAMS - will be appended to throughout script
export EXTRA_GINKGO_PARAMS=${EXTRA_GINKGO_PARAMS:-}
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
LOGS_FOLDER="/alabama/cspi/e2e/logs"

# Extract additional repository archives
mkdir -p {$OADP_GIT_DIR,$OADP_APPS_DIR,$PYCLIENT_DIR}
echo "Extract /home/jenkins/oadp-e2e-qe.tar.gz to ${OADP_GIT_DIR}"
tar -xf /home/jenkins/oadp-e2e-qe.tar.gz -C "${OADP_GIT_DIR}" --strip-components 1
echo "Extract /home/jenkins/oadp-apps-deployer.tar.gz to ${OADP_APPS_DIR}"
tar -xf /home/jenkins/oadp-apps-deployer.tar.gz -C "${OADP_APPS_DIR}" --strip-components 1
# echo "Extract /home/jenkins/mtc-python-client.tar.gz to ${PYCLIENT_DIR}"
# tar -xf /home/jenkins/mtc-python-client.tar.gz -C "${PYCLIENT_DIR}" --strip-components 1

# Setup /tmp/test-settings
echo "Create and populate /tmp/test-settings..."
mkdir -p /tmp/test-settings
cp "${SHARED_DIR}/credentials" /tmp/test-settings
cp "${CLUSTER_PROFILE_DIR}/.awscred" /tmp/test-settings/aws_creds
touch /tmp/test-settings/default_settings.json

# Login to the test cluster as Kubeadmin
echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
mkdir -p /home/jenkins/.kube
touch /home/jenkins/.kube/config

# Login for Interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
#Login for ROSA Classic and Hypershift platforms
else
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

# Setup Python Virtual Environment
echo "Create virtual environment and install required packages..."
python3 -m venv /alabama/venv
source /alabama/venv/bin/activate
python3 -m pip install ansible_runner
python3 -m pip install "${OADP_APPS_DIR}" --target "${OADP_GIT_DIR}/sample-applications/"
# python3 -m pip install "${PYCLIENT_DIR}"

# Install go modules
cd $OADP_GIT_DIR
go mod edit -replace=gitlab.cee.redhat.com/app-mig/oadp-e2e-qe=$OADP_GIT_DIR/e2e
go mod tidy

# Configure default storage class
echo "Storage classes before configuration:"
oc get sc

if [ -n "${STORAGE_CLASS:-}" ]; then
    # STORAGE_CLASS has a value - make it the default
    echo "STORAGE_CLASS env var set to: ${STORAGE_CLASS}"
    if oc get storageclass "${STORAGE_CLASS}" &>/dev/null; then
        echo "Setting ${STORAGE_CLASS} as default storage class"
        oc get storageclass -o name | xargs oc patch -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
        oc patch storageclass "${STORAGE_CLASS}" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
    else
        echo "ERROR: STORAGE_CLASS ${STORAGE_CLASS} does not exist"
    fi
else
    # STORAGE_CLASS is empty - do nothing, leave storage classes as is
    echo "STORAGE_CLASS not set, leaving storage class configuration unchanged"
    # Get the current default storage class for later use
    STORAGE_CLASS=$(oc get storageclass -o jsonpath="{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=='true')].metadata.name}" || echo "")
    if [ -n "${STORAGE_CLASS}" ]; then
        echo "Current default storage class: ${STORAGE_CLASS}"
    else
        echo "No default storage class found in cluster"
    fi
fi

echo "Storage classes after configuration:"
oc get sc

# Export STORAGE_CLASS for test_runner.sh to use
export STORAGE_CLASS
echo "STORAGE_CLASS exported: ${STORAGE_CLASS}"

# Skip VSL tests if NOT using ODF storage class
if [ -n "${STORAGE_CLASS}" ] && [[ "${STORAGE_CLASS}" != odf* ]]; then
    echo "Non-ODF storage class detected (${STORAGE_CLASS}), adding VSL skip parameters"
    EXTRA_GINKGO_PARAMS="${EXTRA_GINKGO_PARAMS} --skip=vsl --skip=VSL"
fi

# Run OADP Kubevirt tests if configured
if [ "$EXECUTE_KUBEVIRT_TESTS" == "true" ]; then
  if [ "$STORAGE_CLASS" == "odf-operator-ceph-rbd-virtualization" ]; then
    echo "Running Kubevirt tests with ODF storage class"
    OADP_TEST_FOCUS=""
    export JUNIT_REPORT_ABS_PATH="${ARTIFACT_DIR}/junit_oadp_cnv_results.xml" &&\
    export TESTS_FOLDER="/alabama/cspi/e2e/kubevirt-plugin" &&\
    export EXTRA_GINKGO_PARAMS="${EXTRA_GINKGO_PARAMS} --skip=tc-id:OADP-555 --skip=tc-id:OADP-186" &&\
    (/bin/bash /alabama/cspi/test_settings/scripts/test_runner.sh || true)
    OADP_TEST_FOCUS=$TEMP_TEST_FOCUS
  else
    echo "Skipping Kubevirt tests - requires odf-operator-ceph-rbd-virtualization storage class (current: ${STORAGE_CLASS})"
  fi
fi

# Run OADP tests with the focus
if [[ "$OADP_TEST_FOCUS" == "--focus=ALL_TESTS" ]]; then
  echo "Running all tests in oadp-e2e-qe"
  OADP_TEST_FOCUS=""
fi
# export NUM_OF_OADP_INSTANCES=3
# Append OADP_TEST_FOCUS to EXTRA_GINKGO_PARAMS instead of overriding
export EXTRA_GINKGO_PARAMS="${EXTRA_GINKGO_PARAMS} ${OADP_TEST_FOCUS}" &&\
export TESTS_FOLDER="/alabama/cspi/e2e" &&\
export JUNIT_REPORT_ABS_PATH="${ARTIFACT_DIR}/junit_oadp_interop_results.xml" &&\
(/bin/bash /alabama/cspi/test_settings/scripts/test_runner.sh || true)

sleep 30

# Copy logs into artifact directory if they exist
echo "Checking for additional logs in ${LOGS_FOLDER}"
if [ -d "${LOGS_FOLDER}" ]; then
    echo "Copying ${LOGS_FOLDER} to ${ARTIFACT_DIR}..."
    ls $LOGS_FOLDER
    cp -r "${LOGS_FOLDER}" "${ARTIFACT_DIR}/logs"
fi
