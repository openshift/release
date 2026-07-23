#!/bin/bash

if [[ -f "${SHARED_DIR}/kubeadmin-password" ]]; then
  QE_KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
  export QE_KUBEADMIN_PASSWORD
  echo "QE_KUBEADMIN_PASSWORD set from cluster credentials"
fi

set -exuo pipefail

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -f "${SHARED_DIR}/runtime_env" ]; then
    source "${SHARED_DIR}/runtime_env"
fi

binhome=$(mktemp -d)
if ! which kubectl; then
  ln -s "$(which oc)" "${binhome}/kubectl"
fi

export PATH="${binhome}:${PATH}"

echo "====> Starting netobserv ginkgo e2e tests"
echo "====> TEST_RUN_MODE: ${TEST_RUN_MODE}"

FOCUS_FILE_ARG=""
LABEL_FILTER_ARG=""
SKIP_FILTER_ARG=""

if [[ -n "${GINKGO_FOCUS_FILE}" ]]; then
  FOCUS_FILE_ARG="--focus-file=${GINKGO_FOCUS_FILE}"
  echo "Using explicit focus-file: ${GINKGO_FOCUS_FILE}"
elif [[ "${TEST_RUN_MODE}" == "premerge" && -f "${SHARED_DIR}/changed_files" ]]; then
  CHANGED_TEST_FILES=""
  while IFS= read -r file; do
    if [[ "${file}" =~ ^integration-tests/backend/(.*_test\.go|test_.*\.go)$ ]]; then
      basename=$(basename "${file}")
      if [[ -n "${CHANGED_TEST_FILES}" ]]; then
        CHANGED_TEST_FILES="${CHANGED_TEST_FILES}|${basename}"
      else
        CHANGED_TEST_FILES="${basename}"
      fi
    fi
  done < "${SHARED_DIR}/changed_files"

  if [[ -z "${CHANGED_TEST_FILES}" ]]; then
    echo "No test files changed in pre-merge mode, skipping tests"
    exit 0
  fi
  FOCUS_FILE_ARG="--focus-file=(${CHANGED_TEST_FILES})"
  echo "Running tests from changed files: ${CHANGED_TEST_FILES}"
else
  echo "Running all tests"
fi

if [[ -n "${GINKGO_LABEL_FILTER}" ]]; then
  LABEL_FILTER_ARG="--label-filter=${GINKGO_LABEL_FILTER}"
  echo "Using label filter: ${GINKGO_LABEL_FILTER}"
fi

if [[ -n "${GINKGO_FOCUS_FILTER}" ]]; then
  FOCUS_FILTER_ARG="--focus=${GINKGO_FOCUS_FILTER}"
  echo "Using focus filter: ${GINKGO_FOCUS_FILTER}"
fi

# skip tests with ginkgo args if they're going to be skipped in generic all tests jobs
if [[ "${JOB_NAME_SAFE}" != *"ipv6"* && "${JOB_NAME_SAFE}" != *"virt"* && "${JOB_NAME_SAFE}" != *"vsphere"* ]]; then
  SPECIALIZED_SKIP="82637|77894|with VMs|53844"
  if [[ -n "${GINKGO_SKIP_FILTER}" ]]; then
    GINKGO_SKIP_FILTER="${GINKGO_SKIP_FILTER}|${SPECIALIZED_SKIP}"
  else
    GINKGO_SKIP_FILTER="${SPECIALIZED_SKIP}"
  fi
  echo "All tests job detected, appending specialized test exclusions to skip filter"
fi

if [[ -n "${GINKGO_SKIP_FILTER}" ]]; then
  SKIP_FILTER_ARG="--skip=${GINKGO_SKIP_FILTER}"
  echo "Using skip filter: ${GINKGO_SKIP_FILTER}"
fi

echo "====> Running ginkgo tests"
# JUNIT_REPORT_FILE is used instead of --junit-report so the test binary can write
# a filtered JUnit XML containing only sig-netobserv specs (via ReportAfterSuite hook).
# Using --junit-report would cause ginkgo to overwrite our filtered output with the full
# unfiltered report (all 7000+ upstream specs) after our hook runs.
export JUNIT_REPORT_FILE="${ARTIFACT_DIR}/junit_netobserv_e2e.xml"
GINKGO_EXIT=0
ginkgo run \
  --timeout="${GINKGO_TIMEOUT}" \
  --v \
  --keep-going \
  --output-dir="${ARTIFACT_DIR}" \
  ${FOCUS_FILTER_ARG:+"${FOCUS_FILTER_ARG}"} \
  ${FOCUS_FILE_ARG:+"${FOCUS_FILE_ARG}"} \
  ${LABEL_FILTER_ARG:+"${LABEL_FILTER_ARG}"} \
  ${SKIP_FILTER_ARG:+"${SKIP_FILTER_ARG}"} \
  ./e2e-tests.test || GINKGO_EXIT=$?

if [[ "${GINKGO_EXIT}" -ne 0 ]]; then
  echo "ginkgo-tests failed with exit code ${GINKGO_EXIT}" >> "${SHARED_DIR}/netobserv-step-failures"
  echo "====> Tests completed with failures (exit ${GINKGO_EXIT}), continuing to next step"
else
  echo "====> Tests completed successfully"
fi
