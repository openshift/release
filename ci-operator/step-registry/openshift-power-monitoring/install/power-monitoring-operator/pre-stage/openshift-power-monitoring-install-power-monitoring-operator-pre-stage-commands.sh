#!/bin/bash

set -eu -o pipefail
set -x
# constants
declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"
declare -r POWERMON_BUNDLE="power-monitoring-operator-bundle-container"
declare -r CATALOG_SOURCE="power-monitoring-operator-catalog"

declare OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-"tech-preview"}
declare OPERATOR=${OPERATOR:-"power-monitoring-operator"}
declare OPERATOR_NS=${OPERATOR_NS:-"openshift-operators"}
declare OCP_VERSION=${OCP_VERSION:-'v4.15'}
declare UMB_MESSAGE="https://datagrepper.engineering.redhat.com/raw?topic=/topic/VirtualTopic.eng.ci.redhat-container-image.index.built&delta=824000&contains=$POWERMON_BUNDLE"
declare INDEX_IMAGE=""

get_index_image() {
	echo "fetching index image"
	local code=0
	code=$(curl -s -o /dev/null -I -w "%{http_code}" "$UMB_MESSAGE")
	echo "Status code: $code"
	curl -s "UMB_MESSAGE"
	INDEX_IMAGE=$(curl -s "$UMB_MESSAGE" | jq --arg requested_ocp_version "$OCP_VERSION" -r '.raw_messages[] | select(.msg.index.ocp_version==$requested_ocp_version) | .msg.index.index_image' | head -n 1 | awk -F ':' '{print "brew.registry.reddhat.io/rh-osbs/iib:"$2}')
	echo "$INDEX_IMAGE"
	until [[ -f /tmp/sleep ]]; do
		echo "sleeping for 5 minutes"
	done

	[[ -n $INDEX_IMAGE && $INDEX_IMAGE != "null" ]] || {
		echo "no matching index image found. Please check if the requested ocp version is valid."
		return 1
	}
	echo "using index image: $INDEX_IMAGE"
	return 0
}

add_catalog_source() {
	echo "adding CatalogSource for power monitoring with index Image..."
	oc apply -f - <<EOF
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: $CATALOG_SOURCE
    namespace: openshift-marketplace
  spec:
    sourceType: grpc
    image: $INDEX_IMAGE
    displayName: Openshift Power Monitoring
    publisher: Power Mon RC Images
EOF
}

create_subscription() {
	echo "creating $OPERATOR subscription from $OPERATOR_CHANNEL inside $OPERATOR_NS namespace"
	# subscribe to the operator
	oc apply -f - <<EOF
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

install_tools() {
	echo "## Install jq"
	curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
	echo "   jq installed"
}

main() {
	mkdir /tmp/bin
	export PATH=$PATH:/tmp/bin/

	install_tools

	get_index_image || {
		echo "error fetching index image. exiting..."
		return 1
	}
	add_catalog_source

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
