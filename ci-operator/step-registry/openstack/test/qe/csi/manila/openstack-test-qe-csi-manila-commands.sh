#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

export OCP_RELEASE="$(<"${SHARED_DIR}/osp_release")"

export JOB_NUMBER="$(<"${SHARED_DIR}/job_number")"

curl "${OCP_TESTING_URL}/${JOB_NUMBER}/artifact/manilacsi-test-results/manilacsi-test.log" > "${ARTIFACT_DIR}/e2e.log"

curl -o "${ARTIFACT_DIR}/junit.zip" "${OCP_TESTING_URL}/${JOB_NUMBER}/artifact/manilacsi-test-results/*zip*/manilacsi-test-results.zip"

unzip ${ARTIFACT_DIR}/junit.zip -d ${ARTIFACT_DIR} && mv ${ARTIFACT_DIR}/manilacsi-test-results ${ARTIFACT_DIR}/junit

rm -f ${ARTIFACT_DIR}/junit.zip

sleep 600