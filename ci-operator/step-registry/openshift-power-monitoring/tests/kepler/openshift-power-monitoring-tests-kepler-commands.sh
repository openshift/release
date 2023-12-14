#!/bin/bash

set -eu -o pipefail

declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"
declare -r OPERATOR_DEPLOY_NAME="kepler-operator-controller"
declare -r OPERATORS_NS="openshift-operators"

declare KEPLER_DEPLOYMENT_NS="${KEPLER_DEPLOYMENT_NS:-kepler-operator}"

validate_install() {
	echo "Validating Operator Install"

	oc rollout status -n "$OPERATORS_NS" "deployment/$OPERATOR_DEPLOY_NAME"
	oc wait --for condition=Available -n "$OPERATORS_NS" --timeout=300s deployment "$OPERATOR_DEPLOY_NAME"
	oc logs -n "$OPERATORS_NS" "deployment/$OPERATOR_DEPLOY_NAME"
}

must_gather() {
	echo "Running must gather"

	echo "Gather OLM resources"

	for x in $(oc api-resources --api-group=operators.coreos.com -o name); do
		oc get "$x" -n "$OPERATORS_NS" -o yaml | tee "$LOGS_DIR/$x.yaml"
	done
	oc get pods -n "$OPERATORS_NS"
	oc describe deployment "$OPERATOR_DEPLOY_NAME" -n "$OPERATORS_NS"
	oc logs -f -n "$OPERATORS_NS" "deployment/$OPERATOR_DEPLOY_NAME"
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
		echo "Operator validation failed"
		return 1
	}

	echo "Running e2e tests"

	log_events "$OPERATORS_NS" &
	log_events "$KEPLER_DEPLOYMENT_NS" &

	local ret=0

	./e2e.test -test.v -test.failfast 2>&1 | tee "$LOGS_DIR/e2e.log" || ret=1

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
