#!/bin/bash

set -x

# Set XDG_RUNTIME_DIR/containers to be used by oc mirror
export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1

function run_command() {
	local CMD="$1"
	echo "Running Command: ${CMD}"
	eval "${CMD}"
}

# Mirror operator and test images to the Mirror registry. Create Catalog sources and Image Content Source Policy.
function mirror_catalog_icsp() {
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
  additionalImages:
  # Used for running disconnected tests
  - name: quay.io/redhat-user-workloads/rhpm-tenant/power-monitoring-operator-bundle:v0.4.0
  - name: quay.io/redhat-user-workloads/rhpm-tenant/power-monitoring-operator:v0.15.0
  - name: quay.io/redhat-user-workloads/rhpm-tenant/kepler:v0.7.12
EOF

	run_command "cd /tmp"
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
      source: quay.io
    - mirrors:
      - $MIRROR_REGISTRY_HOST
      source: registry.redhat.io/openshift-power-monitoring/kepler-rhel9
    - mirrors:
      - $MIRROR_REGISTRY_HOST
      source: registry.redhat.io/openshift-power-monitoring/power-monitoring-rhel9-operator

EOF
	echo "Install operator-sdk and dependencies"
	export OPERATOR_SDK_VERSION=1.36.1
	export ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n $(uname -m) ;; esac)
	export OPERATOR_SDK_DL_URL=https://github.com/operator-framework/operator-sdk/releases/download/v${OPERATOR_SDK_VERSION}
	curl -Lo operator-sdk ${OPERATOR_SDK_DL_URL}/operator-sdk_linux_${ARCH}

	while [[ -f /tmp/unsleep ]]; do
		echo "sleeping for 10 seconds"
		sleep 10
	done

	chmod +x operator-sdk
	./operator-sdk version

	./operator-sdk run bundle --timeout=10m --namespace "openshift-operators" "quay.io/redhat-user-workloads/rhpm-tenant/power-monitoring-operator-bundle:v0.4.0"

	oc logs -n openshift-operators -f deployment/kepler-operator-controller

}

run_command "oc whoami"
run_command "oc version -o yaml"

mirror_catalog_icsp
