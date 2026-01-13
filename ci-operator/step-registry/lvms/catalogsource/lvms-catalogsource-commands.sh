#!/bin/bash

set -euo pipefail

declare -r DISCONNECTED=${DISCONNECTED:-false}
# Define the paths to vault secrets
declare -r MIRROR_REGISTRY_DIR="${MIRROR_REGISTRY_DIR:-"/var/run/vault/mirror-registry"}"
declare -r MIRROR_REGISTRY_CREDS="${MIRROR_REGISTRY_DIR}/registry_creds"
declare -r MIRROR_REGISTRY_CA="${MIRROR_REGISTRY_DIR}/client_ca.crt"

declare -r IDMS_NAME=${IDMS_NAME:-"lvm-operator-idms"}
declare -r CATALOG_SOURCE=${LVM_CATALOG_SOURCE:-"lvm-catalogsource"}
declare LVM_INDEX_IMAGE

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)

echo "Detected OpenShift version: ${CLUSTER_VERSION}"

# lvms-operator exists in Konflux catalogsource index image by default in all versions
LVM_INDEX_IMAGE="quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog:v${CLUSTER_VERSION}"

# Allow overriding the LVM_INDEX_IMAGE with the Gangway API
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LVM_INDEX_IMAGE:-}" ]]; then
  LVM_INDEX_IMAGE=${MULTISTAGE_PARAM_OVERRIDE_LVM_INDEX_IMAGE}
fi

echo "LVM_INDEX_IMAGE is set to: $LVM_INDEX_IMAGE"

function set_proxy {
	if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
		echo "setting the proxy"
		echo "source ${SHARED_DIR}/proxy-conf.sh"
		source "${SHARED_DIR}/proxy-conf.sh"
		# Set no_proxy for required registries in disconnected environments
		export no_proxy=quay.io
		export NO_PROXY=quay.io
	else
		echo "no proxy setting. skipping this step"
	fi
	return 0
}

function run {
	local cmd="$1"
	echo "running command: $cmd"
	eval "$cmd"
}

function disable_default_catalogsource {
	run "oc patch operatorhub cluster -p '{\"spec\": {\"disableAllDefaultSources\": true}}' --type=merge"
	local -i ret=$?
	if [[ $ret -eq 0 ]]; then
		echo "disable default Catalog Source successfully."
	else
		echo "!!! fail to disable default Catalog Source"
		return 1
	fi
	ocp_version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
	major_version=$(echo ${ocp_version} | cut -d '.' -f1)
	minor_version=$(echo ${ocp_version} | cut -d '.' -f2)
	if [[ "${major_version}" == "4" && -n "${minor_version}" && "${minor_version}" -gt 17 ]]; then
		echo "disable olmv1 default clustercatalog"
		run "oc patch clustercatalog openshift-certified-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
		run "oc patch clustercatalog openshift-redhat-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
		run "oc patch clustercatalog openshift-redhat-marketplace -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
		run "oc patch clustercatalog openshift-community-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
		run "oc get clustercatalog"
	fi
	return 0
}

# create IDMS for connected env.
function create_idms_connected {

	cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: $IDMS_NAME
spec:
  imageDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator
    source: registry.redhat.io/lvms4/lvms-rhel9-operator
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-bundle
    source: registry.redhat.io/lvms4/lvms-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvms-must-gather
    source: registry.redhat.io/lvms4/lvms-must-gather-rhel9
EOF

	if [ $? -ne 0 ]; then
		echo "!!! failed to create the IDMS"
		return 1
	fi

	echo "IDMS $IDMS_NAME created successfully"
	return 0
}

# create IDMS for disconnected env with proper mirror configuration
function create_idms_disconnected {
	echo "Creating ImageDigestMirrorSet for LVMS images in disconnected environment"

	cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: $IDMS_NAME
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator
    source: registry.redhat.io/lvms4/lvms-rhel9-operator
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-bundle
    source: registry.redhat.io/lvms4/lvms-operator-bundle
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/lvms-must-gather
    source: registry.redhat.io/lvms4/lvms-must-gather-rhel9
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog
    source: quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog
EOF

	if [ $? -ne 0 ]; then
		echo "!!! failed to create ImageDigestMirrorSet for disconnected environment"
		return 1
	fi

	echo "ImageDigestMirrorSet $IDMS_NAME created successfully for disconnected environment"
	return 0
}

function create_catalog_sources {
	local node_name
	echo "creating catalogsource: $CATALOG_SOURCE using index image: $LVM_INDEX_IMAGE"

	cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE
  namespace: openshift-marketplace
spec:
  displayName: LVM CatalogSource
  image: $LVM_INDEX_IMAGE
  publisher: OpenShift LVM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
	local -i counter=0
	local status=""
	while [ $counter -lt 600 ]; do
		counter+=20
		echo "waiting ${counter}s"
		sleep 20
		status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE" -o=jsonpath="{.status.connectionState.lastObservedState}")
		[[ $status = "READY" ]] && {
			echo "$CATALOG_SOURCE CatalogSource created successfully"
			break
		}
	done
	[[ $status != "READY" ]] && {
		echo "!!! failed to create LVMS CatalogSource"
		run "oc get pods -o wide -n openshift-marketplace"
		run "oc -n openshift-marketplace get catalogsource $CATALOG_SOURCE -o yaml"
		run "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOG_SOURCE -o yaml"
		node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE" -o=jsonpath='{.items[0].spec.nodeName}')
		run "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false \
      pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
		run "oc -n debug-qe debug node/$node_name -- chroot /host podman pull --authfile /var/lib/kubelet/config.json $LVM_INDEX_IMAGE"

		run "oc get mcp,node"
		run "oc get mcp worker -o yaml"
		run "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"

		return 1
	}
	return 0
}

# From 4.11 on, the marketplace is optional.
# That means, once the marketplace disabled, its "openshift-marketplace" project will NOT be created as default.
# But, for OLM, its global namespace still is "openshift-marketplace"(details: https://bugzilla.redhat.com/show_bug.cgi?id=2076878),
# so we need to create it manually so that optional operator teams' test cases can be run smoothly.
function check_marketplace {
	local -i ret=0
	run "oc get ns openshift-marketplace" || ret=1

	[[ $ret -eq 0 ]] && {
		echo "openshift-marketplace project AlreadyExists, skip creating."
		return 0
	}

	cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
EOF
	return 0
}

function set_cluster_auth_disconnected {
	# Set the registry auths for the cluster in disconnected environment
	local registry_cred

	run "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"
	local -i ret=$?
	if [[ $ret -ne 0 ]]; then
		echo "!!! Cannot extract Auth of the cluster"
		return 1
	fi

	# Get mirror registry credential
	registry_cred=$(head -n 1 "$MIRROR_REGISTRY_CREDS" | base64 -w 0)

	# Add mirror registry auth to cluster pull secret
	jq --argjson a "{\"${MIRROR_PROXY_REGISTRY_QUAY}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson

	run "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson"
	ret=$?
	if [[ $ret -eq 0 ]]; then
		echo "Set the mirror registry auth successfully."
		return 0
	else
		echo "!!! fail to set the mirror registry auth"
		return 1
	fi
}

function set_CA_for_nodes {
	local ca_name
	ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
	if [ "$ca_name" ] && [ "$ca_name" = "registry-config" ]; then
		echo "CA is ready, skip config..."
		return 0
	fi

	# Get the QE additional CA
	local QE_ADDITIONAL_CA_FILE
	if [[ "${SELF_MANAGED_ADDITIONAL_CA:-false}" == "true" ]]; then
		QE_ADDITIONAL_CA_FILE="${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt"
	else
		QE_ADDITIONAL_CA_FILE="$MIRROR_REGISTRY_CA"
	fi

	local REGISTRY_HOST

	REGISTRY_HOST=$(echo "${MIRROR_PROXY_REGISTRY_QUAY}" | cut -d: -f1)

	# Configuring additional trust stores for image registry access
	run "oc create configmap registry-config --from-file=\"${REGISTRY_HOST}..5000\"=${QE_ADDITIONAL_CA_FILE} --from-file=\"${REGISTRY_HOST}..6001\"=${QE_ADDITIONAL_CA_FILE} --from-file=\"${REGISTRY_HOST}..6002\"=${QE_ADDITIONAL_CA_FILE} -n openshift-config"
	local -i ret=$?
	if [[ $ret -ne 0 ]]; then
		echo "!!! fail to set the proxy registry ConfigMap"
		run "oc get configmap registry-config -n openshift-config -o yaml"
		return 1
	fi

	run "oc patch image.config.openshift.io/cluster --patch '{\"spec\":{\"additionalTrustedCA\":{\"name\":\"registry-config\"}}}' --type=merge"
	ret=$?
	if [[ $ret -ne 0 ]]; then
		echo "!!! Fail to set additionalTrustedCA"
		run "oc get image.config.openshift.io/cluster -o yaml"
		return 1
	fi

	echo "Set additionalTrustedCA successfully."
	return 0
}

function main {
	echo "Enabling LVM CatalogSource"
	set_proxy

	run "oc whoami"
	run "oc version -o yaml"

	# Check if running in disconnected mode
	if [[ "${DISCONNECTED:-false}" == "true" ]]; then
		echo "Running in DISCONNECTED mode"

		# Set up mirror registry variables
		MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
		MIRROR_PROXY_REGISTRY_QUAY="${MIRROR_REGISTRY_HOST//5000/6001}"

		echo "MIRROR_PROXY_REGISTRY_QUAY: ${MIRROR_PROXY_REGISTRY_QUAY}"

		# Set CA for nodes to trust mirror registry
		set_CA_for_nodes || {
			echo "failed to set CA for nodes. resolve the above errors"
			return 1
		}

		# Set cluster auth for mirror registry
		set_cluster_auth_disconnected || {
			echo "failed to set cluster auth for disconnected environment. resolve the above errors"
			return 1
		}

		# Disable default catalog sources
		disable_default_catalogsource || {
			echo "failed to disable default catalog sources. resolve the above errors"
			return 1
		}

		# Create IDMS for disconnected environment
		create_idms_disconnected || {
			echo "failed to create ImageDigestMirrorSet for disconnected. resolve the above errors"
			return 1
		}

		# Update LVM_INDEX_IMAGE to point to mirrored location
		LVM_INDEX_IMAGE="${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog:v${CLUSTER_VERSION}"
		echo "Updated LVM_INDEX_IMAGE for disconnected: $LVM_INDEX_IMAGE"
	else
		echo "Running in CONNECTED mode"

		create_idms_connected || {
			echo "failed to create imagecontentsourcepolicies. resolve the above errors"
			return 1
		}
	fi

	# Common steps for both modes
	check_marketplace || {
		echo "failed to check marketplace. resolve the above errors"
		return 1
	}

	create_catalog_sources || {
		echo "failed to create catalogsource. resolve the above errors"
		return 1
	}

	# Support hypershift config guest cluster's idms
	oc get ImageDigestMirrorSet -oyaml >/tmp/mgmt_idms.yaml && yq-go r /tmp/mgmt_idms.yaml 'items[*].spec.imageDigestMirrors' - | sed '/---*/d' >"$SHARED_DIR"/mgmt_icsp.yaml
	return 0
}

main
