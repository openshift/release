#!/bin/bash

set -eu -o pipefail

export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1

# constants
declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"

declare OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-"tech-preview"}
declare OPERATOR=${OPERATOR:-"power-monitoring-operator"}
declare OPERATOR_NS=${OPERATOR_NS:-"openshift-operators"}
declare CATALOG_SOURCE=${CATALOG_SOURCE:-"redhat-operators"}
declare MIRROR_KEPLER_IMAGE=${MIRROR_KEPLER_IMAGE:-"quay.io/redhat-user-workloads/rhpm-tenant/kepler"}
declare SOURCE_KEPLER_IMAGE=${SOURCE_KEPLER_IMAGE:-"registry.redhat.io/openshift-power-monitoring/kepler-rhel9"}
declare MIRROR_OPERATOR_IMAGE=${MIRROR_OPERATOR_IMAGE:-"quay.io/redhat-user-workloads/rhpm-tenant/power-monitoring-operator"}
declare SOURCE_OPERATOR_IMAGE=${SOURCE_OPERATOR_IMAGE:-"registry.redhat.io/openshift-power-monitoring/power-monitoring-rhel9-operator"}
declare BREW_REGISTRY=${BREW_REGISTRY:-"brew.registry.redhat.io"}
declare REGISTRY_PROXY=${REGISTRY_PROXY:-"registry-proxy.engineering.redhat.com"}
declare MIRROR_BUNDLE_IMAGE=${MIRROR_BUNDLE_IMAGE:-"quay.io/redhat-user-workloads/rhpm-tenant/power-monitoring-operator-bundle"}
declare SOURCE_BUNDLE_IMAGE=${SOURCE_BUNDLE_IMAGE:-"registry.redhat.io/openshift-power-monitoring/power-monitoring-operator-bundle"}
declare INDEX=${INDEX:-"926635"}

run_command() {
	local CMD="$1"
	echo "Running Command: ${CMD}"
	eval "${CMD}"
}

create_catalogsource() {
	echo "Creating CatalogSource for iib index $INDEX"
	oc apply -f - <<EOF
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: "$CATALOG_SOURCE"
    namespace: openshift-marketplace
  spec:
    displayName: Latest Operators
    image: "$BREW_REGISTRY/rh-osbs/iib:$INDEX"
    publisher: OpenShift Dev
    sourceType: grpc
    updateStrategy:
      registryPoll:
        interval: 15m
EOF
}

create_subscription() {
	echo "creating $OPERATOR subscription from $OPERATOR_CHANNEL inside $OPERATOR_NS namespace"
	# subscribe to the operator
	oc apply -f - <<EOF
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: "$OPERATOR"
    namespace: "$OPERATOR_NS"
  spec:
    channel: "$OPERATOR_CHANNEL"
    installPlanApproval: Automatic
    name: "$OPERATOR"
    source: "$CATALOG_SOURCE"
    sourceNamespace: openshift-marketplace
EOF
}

fetch_images() {

	registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)

	optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
	optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
	qe_registry_auth=$(echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0)

	openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
	openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
	openshifttest_registry_auth=$(echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0)

	brew_auth_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
	brew_auth_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
	brew_registry_auth=$(echo -n "${brew_auth_user}:${brew_auth_password}" | base64 -w 0)

	stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
	stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
	stage_registry_auth=$(echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0)

	redhat_auth_user=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.user')
	redhat_auth_password=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.password')
	redhat_registry_auth=$(echo -n "${redhat_auth_user}:${redhat_auth_password}" | base64 -w 0)

	# run_command "cat ${CLUSTER_PROFILE_DIR}/pull-secret"
	# Running Command: cat /tmp/.dockerconfigjson
	# {"auths":{"ec2-3-92-162-185.compute-1.amazonaws.com:5000":{"auth":"XXXXXXXXXXXXXXXX"}}}
	run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"
	ret=$?
	MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
	echo $MIRROR_REGISTRY_HOST
	if [[ $ret -eq 0 ]]; then
		jq --argjson a "{\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"brew.registry.redhat.io\": {\"auth\": \"$brew_registry_auth\"}, \"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}, \"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" >${XDG_RUNTIME_DIR}/containers/auth.json
		export REG_CREDS=${XDG_RUNTIME_DIR}/containers/auth.json
	else
		echo "!!! fail to extract the auth of the cluster"
		return 1
	fi

	local kepler=""
	local operator=""
	local bundle=""
	cd /tmp
	curl -L -o opm https://github.com/operator-framework/operator-registry/releases/download/v1.51.0/linux-amd64-opm && chmod +x opm
	kepler=$(./opm render "$BREW_REGISTRY/rh-osbs/iib:$INDEX" | grep "$MIRROR_KEPLER_IMAGE" | tail -n 1 | awk -F'@sha256:' '{print $2}' | tr -d '"')
	operator=$(./opm render "$BREW_REGISTRY/rh-osbs/iib:$INDEX" | grep "$MIRROR_OPERATOR_IMAGE" | tail -n 1 | awk -F'@sha256:' '{print $2}' | tr -d '"')
	bundle=$(./opm render "$BREW_REGISTRY/rh-osbs/iib:$INDEX" | grep "$MIRROR_BUNDLE_IMAGE" | tail -n 1 | awk -F'@sha256:' '{print $2}' | tr -d '"')

	echo "Kepler: $kepler"
	echo "Operator: $operator"
	echo "Bundle: $bundle"

	# prepare ImageSetConfiguration
	run_command "mkdir /tmp/images"
	cat <<EOF >/tmp/image-set.yaml
  kind: ImageSetConfiguration
  apiVersion: mirror.openshift.io/v1alpha2
  archiveSize: 30
  storageConfig:
    local:
      path: /tmp/images
  mirror:
    operators:
    - catalog: "$BREW_REGISTRY/rh-osbs/iib:$INDEX"
      targetCatalog: rh-osbs/tempo
      packages:
      - name: tempo-product
        channels:
        - name: stable
    additionalImages:
    # Used for running disconnected tests
    - name: "$MIRROR_KEPLER_IMAGE@sha256:$kepler"
    - name: "$MIRROR_OPERATOR_IMAGE@sha256:$operator"
    - name: "$MIRROR_BUNDLE_IMAGE@sha256:$bundle"
EOF

	run_command "curl -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/oc-mirror.tar.gz && tar -xvzf oc-mirror.tar.gz && chmod +x oc-mirror"
	run_command "./oc-mirror --config=/tmp/image-set.yaml docker://${MIRROR_REGISTRY_HOST} --continue-on-error --ignore-history --source-skip-tls --dest-skip-tls || true"
	run_command "cp oc-mirror-workspace/results-*/mapping.txt ."
	# run_command "sed -e 's|registry.redhat.io|registry.stage.redhat.io|g' -e 's|brew.registry.stage.redhat.io/rh-osbs/tempo|brew.registry.redhat.io/rh-osbs/iib|g' -e 's|brew.registry.stage.redhat.io/rh-osbs/otel|brew.registry.redhat.io/rh-osbs/iib|g' -e 's|brew.registry.stage.redhat.io/rh-osbs/jaeger|brew.registry.redhat.io/rh-osbs/iib|g' mapping.txt > mapping-stage.txt"
	run_command "oc image mirror -a ${REG_CREDS} -f mapping.txt --insecure --filter-by-os='.*'"

	echo "Creating Image Content Source Policy"
	oc apply -f - <<EOF
  apiVersion: operator.openshift.io/v1alpha1
  kind: ImageContentSourcePolicy
  metadata:
    name: test-registry
  spec:
    repositoryDigestMirrors:
    - mirrors:
      - $MIRROR_REGISTRY_HOST
      source: $REGISTRY_PROXY
    - mirrors:
      - $MIRROR_REGISTRY_HOST
      source: $SOURCE_KEPLER_IMAGE
    - mirrors:
      - $MIRROR_REGISTRY_HOST
      source: $SOURCE_OPERATOR_IMAGE
    - mirrors:
      - $MIRROR_REGISTRY_HOST
      source: $SOURCE_BUNDLE_IMAGE
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
main() {
	echo "deploying $OPERATOR on the cluster"

	fetch_images
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
