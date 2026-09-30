#!/bin/bash

set -eu -o pipefail

# constants
declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"

declare OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-"tech-preview"}
declare OPERATOR=${OPERATOR:-"power-monitoring-operator"}
declare OPERATOR_NS=${OPERATOR_NS:-"openshift-operators"}
declare CATALOG_SOURCE=${CATALOG_SOURCE:-"redhat-operators"}

create_subscription() {
	echo "creating $OPERATOR subscription from $OPERATOR_CHANNEL inside $OPERATOR_NS namespace"
	# subscribe to the operator
	cat <<EOF | oc apply -f - || {
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${OPERATOR}"
  namespace: "${OPERATOR_NS}"
spec:
  channel: "${OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: "${OPERATOR}"
  source: "${CATALOG_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF
		echo "failed to create subscription for operator $OPERATOR"
		return 1
	}
	return 0
}

must_gather() {
	echo "getting subscription details"
	oc get subscription "$OPERATOR" -n "$OPERATOR_NS" -o yaml | tee "$LOGS_DIR/subscription.yaml"
	echo "getting deployment details"
	oc get deployment -n "$OPERATOR_NS" -o yaml | tee "$LOGS_DIR/deployment.yaml"
	echo "getting csv details"
	oc get csv -n "$OPERATOR_NS" -o yaml | tee "$LOGS_DIR/csv.yaml"
}

check_for_subscription() {
	local retries=30
	local csv=""

	for i in $(seq "$retries"); do
		csv=$(oc get subscription -n "$OPERATOR_NS" "$OPERATOR" -o jsonpath='{.status.installedCSV}')

		[[ -z "${csv}" ]] && {
			echo "Try ${i}/${retries}: can't get the $OPERATOR yet. Checking again in 30 seconds"
			sleep 30
		}

		[[ $(oc get csv -n "$OPERATOR_NS" "$csv" -o jsonpath='{.status.phase}') == "Succeeded" ]] && {
			echo "csv: $csv is deployed"
			break
		}
	done

	[[ $(oc wait --for=jsonpath='{.status.phase}=Succeeded' csv "$csv" -n "$OPERATOR_NS" --timeout=10m) ]] || {
		echo "error: failed to deploy $OPERATOR"
		echo "running must-gather"
		must_gather
		return 1
	}

	echo "successfully installed $OPERATOR"
	return 0
}
main() {
	echo "deploying $OPERATOR on the cluster"

	create_subscription || {
		echo "check for above errors and retry again"
		return 1
	}
	check_for_subscription || {
		echo "check for above erros and retry again"
		return 1
	}
}
main
