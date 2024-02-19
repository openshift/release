#!/bin/bash

set -eu -o pipefail
# Define the paths to the JSON files
declare -r MASTER_JSON="/var/run/vault/dt-secrets/99-master-it-ca.json"
declare -r WORKER_JSON="/var/run/vault/dt-secrets/99-worker-it-ca.json"
declare -r STAGE_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_stage.json"

declare ICSP_NAME=${ICSP_NAME:-"dt-registry"}
declare CATALOG_SOURCE=${CATALOG_SOURCE:-"dt-catalogsource"}

set_proxy() {
	[[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
		echo "setting the proxy"
		echo "source ${SHARED_DIR}/proxy-conf.sh"
		source "${SHARED_DIR}/proxy-conf.sh"
	}
	echo "no proxy setting. skipping this step"
	return 0
}

run() {
	local cmd="$1"
	echo "running command: $cmd"
	eval "$cmd"
}

apply_mcp_config() {
	# Create the machineconfigs from the JSON files
	oc create -f "$MASTER_JSON"
	oc create -f "$WORKER_JSON"

	echo "sleeping for 10s"
	sleep 10

	local machineCount=0
	local counter=0
	local updatedMachineCount=0
	machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
	while [ "$counter" -lt 1200 ]; do
		sleep 20
		counter+=20
		echo "waiting ${counter}s"
		updatedMachineCount=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
		[[ "$updatedMachineCount" -eq "$machineCount" ]] && {
			echo "MCP updated successfully"
			break
		}
	done
	[[ "$updatedMachineCount" != "$machineCount" ]] && {
		run "oc get mcp,node"
		run "oc get mcp worker -o yaml"
		return 1
	}
	return 0
}

update_global_auth() {
	# Define the new dockerconfig path
	local new_dockerconfig="/tmp/new-dockerconfigjson"
	local stage_auth_user
	local stage_auth_password
	local stage_registry_auth

	# get the current global auth
	run "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp" || {
		echo "!!! fail to get the cluster global auth."
		return 1
	}

	# Read the stage registry credentials from the JSON file
	stage_auth_user=$(jq -r '.user' $STAGE_REGISTRY_PATH)
	stage_auth_password=$(jq -r '.password' $STAGE_REGISTRY_PATH)
	stage_registry_auth=$(echo -n " " "$stage_auth_user":"$stage_auth_password" | base64 -w 0)

	# Create a new dockerconfig with the stage registry credentials without the "email" field
	jq --argjson a "{\"https://registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" >"$new_dockerconfig"

	# update global auth
	local -i ret=0
	run "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=$new_dockerconfig" || ret=$?
	if [[ $ret -eq 0 ]]; then
		apply_mcp_config
		echo "update the cluster global auth successfully."
	else
		echo "failed to add QE optional registry auth, retry and enable log..."
		sleep 1
		ret=0
		run "oc --loglevel=10 set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
		if [[ $ret -eq 0 ]]; then
			echo "update the cluster global auth successfully after retry."
		else
			echo "still fail to add QE optional registry auth after retry"
			return 1
		fi
	fi
	return 0
}

# create ICSP for connected env.
create_icsp_connected() {

	#Delete any existing ImageContentSourcePolicy
	oc delete imagecontentsourcepolicies brew-registry --ignore-not-found=true || {
		echo "failed to delete existing imagecontentsourcepolicies"
		return 1
	}
	oc delete catalogsource qe-app-registry -n openshift-marketplace --ignore-not-found=true || {
		echo "failed to delete existing catalogsource"
		return 1
	}

	cat <<EOF | oc create -f - || {
  apiVersion: operator.openshift.io/v1alpha1
  kind: ImageContentSourcePolicy
  metadata:
    name: $ICSP_NAME
  spec:
    repositoryDigestMirrors:
    - mirrors:
      - registry.stage.redhat.io
      source: registry.redhat.io
EOF
		echo "!!! fail to create the ICSP"
		return 1
	}

	echo "ICSP $ICSP_NAME created successfully"
	return 0
}

create_catalog_sources() {
	local ocp_version=""
	local index_image=""
	local node_name

	# get cluster Major.Minor version
	ocp_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)
	index_image="registry.stage.redhat.io/redhat/redhat-operator-index:v$ocp_version"

	echo "creating catalogsource: $CATALOG_SOURCE"

	cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE
  namespace: openshift-marketplace
spec:
  displayName: Production Operators
  image: $index_image
  publisher: OpenShift QE
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
		echo "!!! fail to create QE CatalogSource"
		run "oc get pods -o wide -n openshift-marketplace"
		run "oc -n openshift-marketplace get catalogsource $CATALOG_SOURCE -o yaml"
		run "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOG_SOURCE -o yaml"
		node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE" -o=jsonpath='{.items[0].spec.nodeName}')
		run "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false \
      pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
		run "oc -n debug-qe debug node/$node_name -- chroot /host podman pull --authfile /var/lib/kubelet/config.json $index_image"

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
check_marketplace() {
	local -i ret=0
	run "oc get ns openshift-marketplace" || ret=1

	[[ $ret -eq 0 ]] && {
		echo "openshift-marketplace project AlreadyExists, skip creating."
		return 0
	}

	cat <<EOF | oc create -f -
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

main() {
	echo "Enabling stage catalogsource"
	set_proxy

	run "oc whoami"
	run "oc version -o yaml"

	update_global_auth || {
		echo "failed to update global auth. resolve the above errors"
		return 1
	}
	echo "sleeping for 5s"
	sleep 5
	create_icsp_connected || {
		echo "failed to create imagecontentsourcepolicies. resolve the above errors"
		return 1
	}
	check_marketplace || {
		echo "failed to check marketplace. resolve the above errors"
		return 1
	}
	create_catalog_sources || {
		echo "failed to create catalogsource. resolve the above errors"
		return 1
	}

	#support hypershift config guest cluster's icsp
	oc get imagecontentsourcepolicy -oyaml >/tmp/mgmt_iscp.yaml && yq-go r /tmp/mgmt_iscp.yaml 'items[*].spec.repositoryDigestMirrors' - | sed '/---*/d' >"$SHARED_DIR"/mgmt_iscp.yaml

}
main
