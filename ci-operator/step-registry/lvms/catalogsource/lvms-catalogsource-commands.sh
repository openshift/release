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

# Source proxy config early so oc commands work in disconnected environments
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
	source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)

echo "Detected OpenShift version: ${CLUSTER_VERSION}"

if [[ "${LVM_CATALOG_SOURCE}" == "redhat-operators" ]]; then
  if [[ -n "${REDHAT_OPERATORS_INDEX_TAG:-}" ]]; then
    # Create a new CatalogSource with a different name to avoid conflicts with the marketplace-managed one
    # Name format: redhat-operators-v4-20 (dots replaced with dashes)
    CATALOG_SOURCE_NAME="redhat-operators-$(echo ${REDHAT_OPERATORS_INDEX_TAG} | sed 's/[.]/-/g')"
    echo "Creating CatalogSource ${CATALOG_SOURCE_NAME} with production image registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}"
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  annotations:
    target.workload.openshift.io/management: '{"effect": "PreferredDuringScheduling"}'
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators
  grpcPodConfig:
    nodeSelector:
      kubernetes.io/os: linux
      node-role.kubernetes.io/master: ""
    priorityClassName: system-cluster-critical
    securityContextConfig: restricted
    tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
    - effect: NoExecute
      key: node.kubernetes.io/unreachable
      operator: Exists
      tolerationSeconds: 120
    - effect: NoExecute
      key: node.kubernetes.io/not-ready
      operator: Exists
      tolerationSeconds: 120
  icon:
    base64data: ""
    mediatype: ""
  image: registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}
  priority: -100
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
    # Wait for CatalogSource to be ready
    for i in $(seq 1 120); do
      echo "Check CatalogSource ${CATALOG_SOURCE_NAME} creating in $i attempts"
      state=$(oc get catalogsources/${CATALOG_SOURCE_NAME} -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)
      if [[ $? -ne 0 || -z "$state" ]]; then
        echo "error: can't get CatalogSource ${CATALOG_SOURCE_NAME} status (retry the $i attempts)"
        sleep 2
        continue
      fi
      echo "CatalogSource state: $state"
      if [ "$state" == "READY" ]; then
        echo "CatalogSource ${CATALOG_SOURCE_NAME} created successfully after waiting $((5*i)) seconds"
        # Write the catalog source name to SHARED_DIR so subsequent steps can use it
        echo "${CATALOG_SOURCE_NAME}" > "${SHARED_DIR}/redhat_operators_catalog_source_name"
        exit 0
      fi
      sleep 5
    done
    echo "Error: CatalogSource ${CATALOG_SOURCE_NAME} failed to become ready"
    oc get catalogsources/${CATALOG_SOURCE_NAME} -n openshift-marketplace -o yaml
    exit 1
  else
    echo "Skipping creating LVM custom catalog source since production catalog is being used."
    exit 0
  fi
fi

# lvms-operator exists in Konflux catalogsource index image by default in all versions
LVM_INDEX_IMAGE="quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog:v${CLUSTER_VERSION}"

declare -r QUAY_API="https://quay.io/api/v1"
declare -r QUAY_REPO="redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog"

resolve_snapshot_to_digest() {
	local snapshot="$1"

	local version_prefix date_str time_str
	version_prefix=$(echo "${snapshot}" | grep -oP 'lvm-operator-catalog-\d+-\d+')
	date_str=$(echo "${snapshot}" | grep -oP '\d{8}(?=-\d{6}-)')
	time_str=$(echo "${snapshot}" | grep -oP '(?<=\d{8}-)\d{6}')

	if [[ -z "${version_prefix}" || -z "${date_str}" || -z "${time_str}" ]]; then
		echo "Cannot parse snapshot name: ${snapshot}" >&2
		return 1
	fi

	local snap_year snap_month snap_day snap_hour snap_min snap_sec snap_epoch
	snap_year=${date_str:0:4}
	snap_month=${date_str:4:2}
	snap_day=${date_str:6:2}
	snap_hour=${time_str:0:2}
	snap_min=${time_str:2:2}
	snap_sec=${time_str:4:2}
	snap_epoch=$(date -d "${snap_year}-${snap_month}-${snap_day}T${snap_hour}:${snap_min}:${snap_sec}Z" +%s 2>/dev/null || echo 0)

	local version_dot
	version_dot=$(echo "${version_prefix}" | sed 's/lvm-operator-catalog-//; s/-/./')

	local tags_json
	tags_json=$(curl -sSL --connect-timeout 10 --max-time 30 \
		"${QUAY_API}/repository/${QUAY_REPO}/tag/?limit=50&filter_tag_name=like:v${version_dot}-")

	local result
	result=$(echo "${tags_json}" | jq -r --arg snap_epoch "${snap_epoch}" --arg vpfx "v${version_dot}-" '
		[.tags[]
		 | select(.name | startswith($vpfx))
		 | select(.name | test("^v[0-9]+\\.[0-9]+-[a-f0-9]{40}$"))
		 | select(.last_modified != null and .last_modified != "")
		 | .tag_epoch = (.last_modified | strptime("%a, %d %b %Y %H:%M:%S %z") | mktime)
		 | .abs_delta = ((.tag_epoch - ($snap_epoch | tonumber)) | fabs)
		] | sort_by(.abs_delta) | .[0] // empty |
		[.name, .manifest_digest] | @tsv
	')

	if [[ -z "${result}" ]]; then
		echo "No matching quay tag found for snapshot ${snapshot}" >&2
		return 1
	fi

	local tag_name digest
	tag_name=$(echo "${result}" | cut -f1)
	digest=$(echo "${result}" | cut -f2)

	echo "Resolved: ${snapshot} → ${tag_name} (${digest})" >&2
	echo "${digest}"
}

# Z-stream presubmit: resolve catalog image from PR content
if [[ -n "${ZSTREAM_VERSION:-}" ]]; then
	if [[ -z "${PULL_NUMBER:-}" ]]; then
		echo "ERROR: ZSTREAM_VERSION is set but PULL_NUMBER is not available"
		exit 1
	fi
	echo "Resolving z-stream catalog image for version ${ZSTREAM_VERSION} from PR #${PULL_NUMBER}"

	catalog_prefix="lvm-operator-catalog-$(echo "${ZSTREAM_VERSION}" | tr '.' '-')"

	pr_files=$(curl -sSL --connect-timeout 10 --max-time 30 \
		"https://api.github.com/repos/openshift/lvm-operator/pulls/${PULL_NUMBER}/files")
	snapshot=$(echo "${pr_files}" | jq -r \
		'[.[] | select(.filename | contains("catalog")) | .patch // ""] | join("\n")' \
		| grep -oP "(?<=snapshot: )${catalog_prefix}\S*" | head -1)

	if [[ -z "${snapshot}" ]]; then
		echo "ERROR: No catalog snapshot found for ${ZSTREAM_VERSION} in PR #${PULL_NUMBER}"
		exit 1
	fi
	echo "Found snapshot: ${snapshot}"

	digest=$(resolve_snapshot_to_digest "${snapshot}")
	if [[ -z "${digest}" ]]; then
		echo "ERROR: Failed to resolve snapshot ${snapshot} to a quay.io digest"
		exit 1
	fi

	LVM_INDEX_IMAGE="quay.io/${QUAY_REPO}@${digest}"
	echo "Resolved z-stream catalog image: ${LVM_INDEX_IMAGE}"

# Allow overriding the LVM_INDEX_IMAGE with the Gangway API
elif [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LVM_INDEX_IMAGE:-}" ]]; then
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
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/topolvm
    source: registry.redhat.io/lvms4/topolvm-rhel9
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
    - ${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/topolvm
    source: registry.redhat.io/lvms4/topolvm-rhel9
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_QUAY}/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog
    source: quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog
EOF

	if [ $? -ne 0 ]; then
		echo "!!! failed to create ImageDigestMirrorSet for disconnected environment"
		return 1
	fi

	echo "ImageDigestMirrorSet $IDMS_NAME created successfully for disconnected environment"

	cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ${IDMS_NAME}-tag
spec:
  imageTagMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/rhel8/support-tools
    source: registry.redhat.io/rhel8/support-tools
EOF

	if [ $? -ne 0 ]; then
		echo "!!! failed to create the ITMS for disconnected environment"
		return 1
	fi

	echo "ITMS ${IDMS_NAME}-tag created successfully for disconnected environment"
	return 0
}

function mirror_test_images {
	echo "Pre-mirroring test dependency images to mirror registry (port 5000)"

	local new_pull_secret="/tmp/mirror-pull-secret.json"
	local registry_cred
	registry_cred=$(head -n 1 "$MIRROR_REGISTRY_CREDS" | base64 -w 0)

	jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" \
		'.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

	local image="registry.redhat.io/rhel8/support-tools:latest=${MIRROR_REGISTRY_HOST}/rhel8/support-tools:latest"
	local retries=0
	echo "Mirroring $image"
	until oc image mirror "$image" --insecure=true -a "${new_pull_secret}" \
		--skip-verification=true --keep-manifest-list=true --filter-by-os='.*'; do
		if [[ $retries -eq 5 ]]; then
			echo "Failed to mirror support-tools image after 5 attempts"
			rm -f "${new_pull_secret}"
			return 1
		fi
		echo "Failed to mirror image, retrying in 10s..."
		sleep 10
		((retries+=1))
	done

	echo "Successfully mirrored support-tools image to ${MIRROR_REGISTRY_HOST}"
	rm -f "${new_pull_secret}"
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
	jq --argjson a "{\"${MIRROR_PROXY_REGISTRY_QUAY}\": {\"auth\": \"$registry_cred\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson

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

		# Create IDMS/ITMS for disconnected environment
		create_idms_disconnected || {
			echo "failed to create ImageDigestMirrorSet for disconnected. resolve the above errors"
			return 1
		}

		# Pre-mirror test dependency images to port 5000 while MCP rollout is in progress
		mirror_test_images || {
			echo "failed to mirror test images. resolve the above errors"
			return 1
		}

		echo "Waiting for MachineConfigPool to finish rollout after IDMS changes..."
		oc wait mcp --all --for=condition=Updating --timeout=5m || true
		oc wait mcp --all --for=condition=Updated --timeout=20m || true
		echo "MCP rollout completed"

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

	# Extract source commit from catalog image for integration test builds
	oc image info --filter-by-os=linux/amd64 --output=json "${LVM_INDEX_IMAGE}" \
		| jq -r '.config.config.Labels["vcs-ref"]' > "${SHARED_DIR}/lvm_source_commit" 2>/dev/null || true

	return 0
}

main
