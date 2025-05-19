#!/bin/bash

set -e
set -u
set -o pipefail

run() {
        local cmd="$1"
        echo "running command: $cmd"
        eval "$cmd"
}

set_proxy() {
        [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
                echo "setting the proxy"
                echo "source ${SHARED_DIR}/proxy-conf.sh"
                source "${SHARED_DIR}/proxy-conf.sh"
        }
        echo "no proxy setting. skipping this step"
        return 0
}

# create ICSP for connected env.
create_icsp_connected() {
	#Delete any existing ImageContentSourcePolicy
	oc delete imagecontentsourcepolicies brew-registry --ignore-not-found=true || {
		echo "failed to delete existing imagecontentsourcepolicies"
		return 1
	}

	cat <<EOF | oc apply -f - || {
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: $ICSP_NAME
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator-bundle
    source: registry.redhat.io/compliance/openshift-file-integrity-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/ocp-isc-tenant/file-integrity-operator
    source: registry.redhat.io/compliance/openshift-file-integrity-rhel8-operator
EOF
		echo "!!! fail to create the ICSP"
		return 1
	}

	echo "ICSP $ICSP_NAME created successfully"
	return 0
}

create_catalog_sources() {
	local node_name
	echo "creating catalogsource: $CATALOG_SOURCE_NAME using index image: $INDEX_IMAGE"

	cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE_NAME
  namespace: openshift-marketplace
spec:
  displayName: Konflux
  image: $INDEX_IMAGE
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
		status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" -o=jsonpath="{.status.connectionState.lastObservedState}")
		[[ $status = "READY" ]] && {
			echo "$CATALOG_SOURCE_NAME CatalogSource created successfully"
			break
		}
	done
	[[ $status != "READY" ]] && {
		echo "!!! fail to create CatalogSource"
		run "oc get pods -o wide -n openshift-marketplace"
		run "oc -n openshift-marketplace get catalogsource $CATALOG_SOURCE_NAME -o yaml"
		run "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOG_SOURCE_NAME -o yaml"
		node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource="$CATALOG_SOURCE_NAME" -o=jsonpath='{.items[0].spec.nodeName}')
		run "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false \
      pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
		run "oc -n debug-qe debug node/$node_name -- chroot /host podman pull --authfile /var/lib/kubelet/config.json $INDEX_IMAGE"

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

main() {
	echo "Enabling konflux catalogsource"
	set_proxy

	run "oc whoami"
	run "oc version -o yaml"

	if [ -z "${INDEX_IMAGE}" ]; then
		echo "'INDEX_IMAGE' is empty. Skipping catalog source creation..."
		exit 0
	fi

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
    oc get imagecontentsourcepolicy -oyaml >/tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' - | sed '/---*/d' >"$SHARED_DIR"/mgmt_icsp.yaml
}
main
