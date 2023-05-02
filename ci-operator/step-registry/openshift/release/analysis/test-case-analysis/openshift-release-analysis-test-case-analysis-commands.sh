#!/bin/bash

set -o nounset
set +o errexit
set -o pipefail

DEFAULT_MINIMUM_SUCCESSFUL_COUNT=2
TEST_GROUP=install
PIDS=""

function save_pid() {
	PIDS="$PIDS $1"
	echo "PID is $1"
}


echo
echo "********** Starting testcase analysis for:  aws-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  aws-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  azure-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=azure \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/azure-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  gcp-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=gcp \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/gcp-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  vsphere-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  vsphere-ovn-upi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=ovn \
	--infrastructure=upi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-ovn-upi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  vsphere-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=vsphere \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/vsphere-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  metal-ovn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=metal \
	--network=ovn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/metal-ovn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for:  metal-sdn-ipi "
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=metal \
	--network=sdn \
	--infrastructure=ipi \
	--minimum-successful-count=${DEFAULT_MINIMUM_SUCCESSFUL_COUNT} \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/metal-sdn-ipi \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo
echo "********** Starting testcase analysis for aws proxy jobs"
echo
job-run-aggregator analyze-test-case \
	--google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
	--payload-tag=${PAYLOAD_TAG} \
	--platform=aws \
	--include-job-names=ovn-proxy \
	--minimum-successful-count=1 \
	--job-start-time=${JOB_START_TIME} \
	--working-dir=${ARTIFACT_DIR}/aws-proxy \
	--timeout=4h30m \
	--test-group=${TEST_GROUP} &
save_pid $!

echo "Waiting for pids to complete: $PIDS"
ret=0
for pid in $PIDS
do
	echo "[$(date)] waiting for $pid"
	wait "$pid"
	if [ $? -gt 0 ]; then
		ret=$?
		echo "[$(date)] $pid finished with ret=$ret"
	else
		echo "[$(date)] $pid finished successfully"
	fi
done

echo "Exiting with ret=${ret}"
exit "${ret}"
