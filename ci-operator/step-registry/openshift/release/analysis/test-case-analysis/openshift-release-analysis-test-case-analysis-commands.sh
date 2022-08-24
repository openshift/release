#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo
echo "********** Starting testcase analysis for:  aws-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  aws-ovn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--network=ovn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-ovn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  aws-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  aws-sdn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--network=sdn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-sdn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  azure-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=azure \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/azure-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  azure-ovn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=azure \
	--network=ovn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/azure-ovn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  azure-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=azure \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/azure-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  azure-sdn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=azure \
	--network=sdn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/azure-sdn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  gcp-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=gcp \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/gcp-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  gcp-ovn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=gcp \
	--network=ovn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/gcp-ovn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  gcp-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=gcp \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/gcp-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  gcp-sdn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=gcp \
	--network=sdn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/gcp-sdn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  vsphere-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  vsphere-ovn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=ovn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-ovn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  vsphere-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  vsphere-sdn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=sdn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-sdn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  metal-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=metal \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/metal-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  metal-ovn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=metal \
	--network=ovn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/metal-ovn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  metal-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=metal \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/metal-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

echo
echo "********** Starting testcase analysis for:  metal-sdn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=metal \
	--network=sdn \
	--infrastructure=upi \
	--minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/metal-sdn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP}

