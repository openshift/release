#!/bin/bash

set -eu -o pipefail

declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"
declare -r KEPLER_DEPLOY_NAME="kepler-exporter"
declare -r KEPLER_NS="kepler"

validate_install() {
	echo "Validating Kepler Install"

	oc rollout status -n "$KEPLER_NS" daemonset "$KEPLER_DEPLOY_NAME" --timeout 5m || {
		return 1
	}
	oc logs -n "$KEPLER_NS" "daemonset/$KEPLER_DEPLOY_NAME"
	return 0
}

must_gather() {
	echo "Running must gather"
	oc get pods -n "$KEPLER_NS"
	oc describe daemonset "$KEPLER_DEPLOY_NAME" -n "$KEPLER_NS"
	oc logs -n "$KEPLER_NS" "daemonset/$KEPLER_DEPLOY_NAME"
}
log_events() {
	local ns="$1"
	shift
	oc get events -w \
		-o custom-columns=FirstSeen:.firstTimestamp,LastSeen:.lastTimestamp,Count:.count,From:.source.component,Type:.type,Reason:.reason,Message:.message \
		-n "$ns" | tee "$LOGS_DIR/$ns-events.log"
}
main() {
	mkdir -p "$LOGS_DIR"
	validate_install || {
		must_gather
		echo "Kepler validation failed"
		return 1
	}

	echo "Running e2e tests"

	log_events "$KEPLER_NS" &

	local ret=0

	./integration-test.test -test.v -test.failfast 2>&1 | tee "$LOGS_DIR/e2e.log" || ret=1

	# terminating both log_events
	{ jobs -p | xargs -I {} -- pkill -TERM -P {}; } || true
	wait
	sleep 1

	[[ "$ret" -ne 0 ]] && {
		must_gather
		echo "e2e tests failed"
		return $ret
	}
	echo "e2e tests passed"
	return $ret
}
main "$@"
