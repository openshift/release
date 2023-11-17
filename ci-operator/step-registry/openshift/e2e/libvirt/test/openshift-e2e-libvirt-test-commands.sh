#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH

# Initial check
case "${CLUSTER_TYPE}" in
libvirt-ppc64le|libvirt-s390x|powervs*)
    ;;
*)
    >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
    ;;
esac

function upgrade() {
    set -x
    openshift-tests run-upgrade all \
        --to-image "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --provider "${TEST_PROVIDER:-}" \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
}

function log_to_file() {
	local LOG_FILE=$1

	# Close STDOUT file descriptor
	exec 1<&-
	# Close STDERR FD
	exec 2<&-
	# Open STDOUT as $LOG_FILE file for read and write.
	exec 1<>${LOG_FILE}
	# Redirect STDERR to STDOUT
	exec 2>&1
}

function urlencode() {
	local DATA=$1

	echo "${DATA}" | jq -sRr @uri
}

function prometheus_var_init() {
	HOSTNAME=$(oc get routes/prometheus-k8s -n openshift-monitoring -o json | jq -r '.spec.host')
	# Do not exit with err if a token was not obtained. Collecting metrics is optional and should not fail the whole run
	TOKEN=$(oc -n openshift-monitoring sa get-token prometheus-k8s || true)
	export HOSTNAME
	export TOKEN
}

function prometheus_query() {
	local DATA=$1
	local EDATA
	local URL

	EDATA=$(urlencode "${DATA}")
	URL="https://${HOSTNAME}/api/v1/query?query=${EDATA}"
	RESPONSE=$(curl --silent --insecure --header "Authorization: Bearer ${TOKEN}" "${URL}")
	RC=$?
	if [[ ${RC} -gt 0 ]]
	then
		echo "Error: ${URL} returned ${RC}"
		exit 1
	fi
	STATUS=$(echo "${RESPONSE}" | jq -r '.status')
	if [[ "${STATUS}" != "success" ]]
	then
		echo "Error: Status is not success (${STATUS})"
		exit 1
	fi
	RETURNED=$(echo "${RESPONSE}" | jq -r '.data.result[0].value[1]')
	echo "${RETURNED}"
}

function prometheus_all_alerts() {
	local URL="https://${HOSTNAME}/api/v1/alerts"

	RESPONSE=$(curl --silent --insecure --header "Authorization: Bearer ${TOKEN}" "${URL}")
	RC=$?
	if [[ ${RC} -gt 0 ]]
	then
		echo "Error: ${URL} returned ${RC}"
		exit 1
	fi
	jq -r '.data.alerts[]' <<< "${RESPONSE}"
}

function prometheus_alert() {
	local ALERT=$1
	local RESPONSE

	RESPONSE=$(prometheus_all_alerts)

	jq -r 'select(.labels.alertname=="'${ALERT}'")' <<< "${RESPONSE}"
	RC=$?
	if [ ${RC} -gt 0 ]
	then
		echo "ERROR: \'${RESPONSE}\'"
	fi
}

function prometheus_kaebb_loop() {
	local BR1h
	local BR5m
	local BR6h
	local BR30m
	local BR1d
	local BR2h
	local BR3d
	local BR6h

	log_to_file "${ARTIFACT_DIR}/prometheus-kaebb.log"

	while true
	do
		echo "8<----------8<---------- $(date +%s) 8<----------8<----------"

		BR1h=$(prometheus_query 'sum(apiserver_request:burnrate1h)')
		BR5m=$(prometheus_query 'sum(apiserver_request:burnrate5m)')
		BR6h=$(prometheus_query 'sum(apiserver_request:burnrate6h)')
		BR30m=$(prometheus_query 'sum(apiserver_request:burnrate30m)')
		BR1d=$(prometheus_query 'sum(apiserver_request:burnrate1d)')
		BR2h=$(prometheus_query 'sum(apiserver_request:burnrate2h)')
		BR3d=$(prometheus_query 'sum(apiserver_request:burnrate3d)')
		BR6h=$(prometheus_query 'sum(apiserver_request:burnrate6h)')

		echo "BR1h=${BR1h}"
		echo "BR5m=${BR5m}"
		echo "BR6h=${BR6h}"
		echo "BR30m=${BR30m}"
		echo "BR1d=${BR1d}"
		echo "BR2h=${BR2h}"
		echo "BR3d=${BR3d}"
		echo "BR6h=${BR6h}"

		prometheus_alert "KubeAPIErrorBudgetBurn"

		sleep 5m
	done
}

function prometheus_cmrss_loop() {
	local CMRSS_DATA
	local CMRSS_EDATA
	local URL

	CMRSS_DATA='( container_memory_rss{id="/system.slice"} and container_memory_rss{node=~".*worker.*"} )'
	CMRSS_EDATA=$(urlencode "${CMRSS_DATA}")
	URL="https://${HOSTNAME}/api/v1/query?query=${CMRSS_EDATA}"

	log_to_file "${ARTIFACT_DIR}/prometheus-cmrss.log"

	while true
	do
		echo "8<----------8<---------- $(date +%s) 8<----------8<----------"

		RESPONSE=$(curl --silent --insecure --header "Authorization: Bearer ${TOKEN}" "${URL}")
		RC=$?
		if [[ ${RC} -gt 0 ]]
		then
			echo "Error: ${URL} returned ${RC}"
			exit 1
		fi
		STATUS=$(echo "${RESPONSE}" | jq -r '.status')
		if [[ "${STATUS}" != "success" ]]
		then
			echo "Error: Status is not success (${STATUS})"
			exit 1
		fi
		RETURNED1=$(echo "${RESPONSE}" | jq -r '.data.result[0].value[1]')
		RETURNED2=$(echo "${RESPONSE}" | jq -r '.data.result[1].value[1]')
		echo "${RETURNED1} ${RETURNED2}"

		prometheus_alert "SystemMemoryExceedsReservation"

		sleep 5m
	done
}

function prometheus_GRPCRequestsSlow_loop() {
	local EDWFDSB_DATA
	local EDWFDSB_EDATA
	local GSHSB_DATA
	local GSHSB_EDATA
	local ENPRTTSB_DATA
	local ENPRTTSB_EDATA
	local SLEEP_TIME="10m"

	# historgram_quantile:sum:rate:etcd_disk_wal_fsync_duration_seconds_bucket topk(1, histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket{job=~".*etcd.*"}[5m])))
	EDWFDSB_DATA='histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket{job=~".*etcd.*"}['${SLEEP_TIME}']))'
	EDWFDSB_EDATA=$(urlencode "${EDWFDSB_DATA}")
	# historgram_quantile:sum:rate:grpc_server_handling_seconds_bucket topk(1,histogram_quantile(0.99, sum(rate(grpc_server_handling_seconds_bucket{job=~".*etcd.*", grpc_type="unary"}[5m])) without(grpc_type)))
	GSHSB_DATA='histogram_quantile(0.99, sum(rate(grpc_server_handling_seconds_bucket{job=~".*etcd.*", grpc_type="unary"}['${SLEEP_TIME}'])) without(grpc_type)) >= 0'
	GSHSB_EDATA=$(urlencode "${GSHSB_DATA}")
	# historgram_quantile:sum:rate:etcd_network_peer_round_trip_time_seconds_bucket topk(1, histogram_quantile(0.99, rate(etcd_network_peer_round_trip_time_seconds_bucket{job=~".*etcd.*"}[5m])))
	ENPRTTSB_DATA='histogram_quantile(0.99, rate(etcd_network_peer_round_trip_time_seconds_bucket{job=~".*etcd.*"}['${SLEEP_TIME}']))'
	ENPRTTSB_EDATA=$(urlencode "${ENPRTTSB_DATA}")

	log_to_file "${ARTIFACT_DIR}/prometheus-GRPCRequestsSlow.log"

	while true
	do
		echo "8<----------8<---------- $(date +%s) 8<----------8<----------"
		echo "${EDWFDSB_DATA}"

		RESPONSE=$(curl --silent --insecure --header "Authorization: Bearer ${TOKEN}" "https://${HOSTNAME}/api/v1/query?query=${EDWFDSB_EDATA}")
		RC=$?
		if [[ ${RC} -gt 0 ]]
		then
			echo "Error: ${URL} returned ${RC}"
			exit 1
		fi
		STATUS=$(echo "${RESPONSE}" | jq -r '.status')
		if [[ "${STATUS}" != "success" ]]
		then
			echo "Error: Status is not success (${STATUS})"
			exit 1
		fi

		echo "${RESPONSE}" | jq -r '.data.result[] | [ .metric.pod , .value[1] ]'

		echo "8<----------8<----------"
		echo "${GSHSB_DATA}"

		RESPONSE=$(curl --silent --insecure --header "Authorization: Bearer ${TOKEN}" "https://${HOSTNAME}/api/v1/query?query=${GSHSB_EDATA}")
		RC=$?
		if [[ ${RC} -gt 0 ]]
		then
			echo "Error: ${URL} returned ${RC}"
			exit 1
		fi
		STATUS=$(echo "${RESPONSE}" | jq -r '.status')
		if [[ "${STATUS}" != "success" ]]
		then
			echo "Error: Status is not success (${STATUS})"
			exit 1
		fi

		echo "${RESPONSE}" | jq -r '.data.result'

		echo "8<----------8<----------"
		echo "${ENPRTTSB_DATA}"

		RESPONSE=$(curl --silent --insecure --header "Authorization: Bearer ${TOKEN}" "https://${HOSTNAME}/api/v1/query?query=${ENPRTTSB_EDATA}")
		RC=$?
		if [[ ${RC} -gt 0 ]]
		then
			echo "Error: ${URL} returned ${RC}"
			exit 1
		fi
		STATUS=$(echo "${RESPONSE}" | jq -r '.status')
		if [[ "${STATUS}" != "success" ]]
		then
			echo "Error: Status is not success (${STATUS})"
			exit 1
		fi

		echo "${RESPONSE}" | jq -r '.data.result'

		echo "8<----------8<----------"

		prometheus_alert "etcdGRPCRequestsSlow"

		sleep ${SLEEP_TIME}
	done
}

function oc_adm_top_nodes_loop() {
	log_to_file "${ARTIFACT_DIR}/oc-adm-top-nodes.log"

	while true
	do
		echo "8<----------8<---------- $(date +%s) 8<----------8<----------"

		oc adm top nodes --use-protocol-buffers

		sleep 5m
	done
}

function suite() {
    if [ -f "${SHARED_DIR}/excluded_tests" ]; then
        cat > ${SHARED_DIR}/invert_excluded.py <<EOSCRIPT
#!/usr/libexec/platform-python
import sys
all_tests = set()
excluded_tests = set()
for l in sys.stdin.readlines():
    all_tests.add(l.strip())
with open(sys.argv[1], "r") as f:
    for l in f.readlines():
        excluded_tests.add(l.strip())
test_suite = all_tests - excluded_tests
for t in test_suite:
    print(t)
EOSCRIPT
        chmod +x ${SHARED_DIR}/invert_excluded.py
        openshift-tests run "${TEST_SUITE}" --dry-run | ${SHARED_DIR}/invert_excluded.py ${SHARED_DIR}/excluded_tests > ${SHARED_DIR}/tests
        TEST_ARGS="${TEST_ARGS:-} --file ${SHARED_DIR}/tests"
    fi

    case ${BRANCH} in
    4.6)
# use s390x or ppc64le builds of e2e test images
# this is a multi-arch image
        cat << EOREGISTRY > ${SHARED_DIR}/kube-test-repo-list
dockerGluster: quay.io/sjenning
dockerLibraryRegistry: quay.io/sjenning
e2eRegistry: quay.io/multiarch-k8s-e2e
e2eVolumeRegistry: quay.io/multiarch-k8s-e2e
quayIncubator: quay.io/multiarch-k8s-e2e
quayK8sCSI: quay.io/multiarch-k8s-e2e
k8sCSI: quay.io/multiarch-k8s-e2e
promoterE2eRegistry: quay.io/multiarch-k8s-e2e
sigStorageRegistry: quay.io/multiarch-k8s-e2e
EOREGISTRY
export KUBE_TEST_REPO_LIST=${SHARED_DIR}/kube-test-repo-list
        ;;
    4.[789]|4.10)
        TEST_ARGS="${TEST_ARGS:-} --from-repository=quay.io/multi-arch/community-e2e-images"
        ;;
    esac

    VERBOSITY="" # "--v 9"
    set -x
    openshift-tests run \
        ${VERBOSITY} \
        "${TEST_SUITE}" \
        ${TEST_ARGS:-} \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
}

function heavy_build() {
    TEST_ARGS="${TEST_ARGS:-} --file ${SHARED_DIR}/tests"
    VERBOSITY="" # "--v 9"

    set -x
    openshift-tests run \
        ${VERBOSITY} \
        "${TEST_SUITE}" \
        ${TEST_ARGS:-} \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit" &
    wait "$!"
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_START"
trap 'echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_TEST_END"' EXIT

declare -a WATCHERS

trap 'echo "Killing WATCHERS"; for PID in ${WATCHERS[@]}; do kill -9 ${PID} >/dev/null 2>&1 || true; done' TERM

prometheus_var_init
if [ -n "$TOKEN" ]; then
    prometheus_cmrss_loop &
	WATCHERS+=( "$!" )

	prometheus_kaebb_loop &
	WATCHERS+=( "$!" )

	prometheus_GRPCRequestsSlow_loop &
	WATCHERS+=( "$!" )
else
    echo "Failed to get a token from prometheus service account. Skipping metrics collection"
fi

oc_adm_top_nodes_loop &
WATCHERS+=( "$!" )

case "${TEST_TYPE}" in
conformance-parallel)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel suite
    ;;
conformance-serial)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/serial suite
    ;;
jenkins-e2e-rhel-only)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/jenkins-e2e-rhel-only suite
    ;;
image-ecosystem)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/image-ecosystem suite
    ;;
heavy-build)
    TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE=openshift/conformance/parallel heavy_build
    ;;
upgrade)
    upgrade
    ;;
suite)
    suite
    ;;
*)
    echo >&2 "Unsupported test type '${TEST_TYPE}'"
    exit 1
    ;;
esac
