#!/bin/bash

if [[ -f "${SHARED_DIR}/kubeadmin-password" ]]; then
  QE_KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
  export QE_KUBEADMIN_PASSWORD
  echo "QE_KUBEADMIN_PASSWORD set from cluster credentials"
fi

set -exuo pipefail
echo "====> Starting netobserv ginkgo e2e tests"
echo "====> TEST_RUN_MODE: ${TEST_RUN_MODE}"

FOCUS_FILE_ARG=""
LABEL_FILTER_ARG=""

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

echo "====> Running ginkgo tests"
ginkgo run \
  --timeout="${GINKGO_TIMEOUT}" \
  --v \
  --keep-going \
  --junit-report=junit_netobserv_e2e.xml \
  --output-dir="${ARTIFACT_DIR}" \
  ${FOCUS_FILE_ARG:+"${FOCUS_FILE_ARG}"} \
  ${LABEL_FILTER_ARG:+"${LABEL_FILTER_ARG}"} \
  ./e2e-tests.test

echo "====> Tests completed successfully"
