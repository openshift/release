#!/bin/bash

set -e
set -u
set -o pipefail

# Function to print timestamped messages
log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run() {
	local cmd="$1"
	log "running command: $cmd"
	eval "$cmd"
}

set_proxy() {
	if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
		log "setting the proxy"
		source "${SHARED_DIR}/proxy-conf.sh"
	else
		log "no proxy setting. skipping this step"
	fi
	return 0
}

# Get hosted cluster name
get_hosted_cluster_name() {
	local hc_name

	source "${SHARED_DIR}/hosted_cluster.txt"

	if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
		hc_name=$(cat "${SHARED_DIR}/cluster-name")
	elif [[ -n "${CLUSTER_NAME:-}" ]]; then
		hc_name="${CLUSTER_NAME}"
	else
		log "Error: Cannot determine hosted cluster name"
		return 1
	fi
	echo "$hc_name"
}

# Get hosted cluster namespace
get_hosted_cluster_namespace() {
	local hc_name="$1"
	local namespace
	namespace=$(oc get hostedclusters.hypershift.openshift.io -A -o jsonpath="{.items[?(@.metadata.name==\"$hc_name\")].metadata.namespace}")
	if [[ -z "$namespace" ]]; then
		log "Error: Cannot determine hosted cluster namespace for $hc_name"
		return 1
	fi
	echo "$namespace"
}

# Create imageContentSources patch for HostedCluster
create_patch_file() {
	local patch_file="${SHARED_DIR}/idms_patch.json"

	cat >"$patch_file" <<EOF
{
  "spec": {
    "imageDigestMirrors": [
      {
        "mirrors": [
          "quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-operator-main"
        ],
        "source: registry.redhat.io/kueue/kueue-rhel9-operator"
      },
      {
        "mirrors": [
          "quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-operand-main"
        ],
        "source: registry.redhat.io/kueue/kueue-rhel9"
      },
      {
        "mirrors": [
          "quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-must-gather-main"
        ],
        "source: registry.redhat.io/kueue/kueue-must-gather-rhel9"
      }
    ]
  }
}
EOF

	log "Created patch file at $patch_file"
	log "Patch content:"
	cat "$patch_file"
}

wait_nodepools_updating() {
	local hc_name="$1"
	local hc_namespace="$2"
	local guest_kubeconfig="${SHARED_DIR}/nested_kubeconfig"

	log "Starting to wait for nodepools updating for hosted cluster: $hc_name in namespace: $hc_namespace"

	# Wait until nodepools update done
	local counter=0
	local timeout=2000
	while [[ $counter -lt $timeout ]]; do
		sleep 20
		counter=$((counter + 20))

		local nodepools
		nodepools=$(oc get nodepools -n "$hc_namespace" -o jsonpath='{.items[?(@.spec.clusterName=="'$hc_name'")].metadata.name}')

		if [[ -z "$nodepools" ]]; then
			log "No nodepools found for hosted cluster $hc_name, trying alternative label selector..."
			nodepools=$(oc get nodepools -n "$hc_namespace" -l "hypershift.openshift.io/hosted-cluster=$hc_name" -o jsonpath='{.items[*].metadata.name}')
		fi

		if [[ -z "$nodepools" ]]; then
			log "Warning: No nodepools found for hosted cluster $hc_name in namespace $hc_namespace"
			log "Available nodepools in namespace $hc_namespace:"
			oc get nodepools -n "$hc_namespace" -o name || log "Failed to list nodepools"
			continue
		fi

		log "Found nodepools: $nodepools"

		local all_ready=true
		local updating_count=0
		local ready_count=0

		for np in $nodepools; do
			# Get multiple status conditions for detailed info
			local updating_status
			local ready_status
			local replicas_status

			updating_status=$(oc get nodepool "$np" -n "$hc_namespace" -o=jsonpath='{.status.conditions[?(@.type=="UpdatingConfig")].status}' 2>/dev/null || echo "Unknown")
			ready_status=$(oc get nodepool "$np" -n "$hc_namespace" -o=jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
			replicas_status=$(oc get nodepool "$np" -n "$hc_namespace" -o=jsonpath='{.spec.replicas},{.status.replicas}' 2>/dev/null || echo "Unknown,Unknown")

			log "  Nodepool $np status - UpdatingConfig: $updating_status, Ready: $ready_status, Replicas: $replicas_status"

			if [[ "$updating_status" == "True" ]]; then
				all_ready=false
				updating_count=$((updating_count + 1))
			else
				ready_count=$((ready_count + 1))
			fi
		done

		local total_count
		total_count=$(echo "$nodepools" | wc -w)
		log "Summary: $ready_count ready, $updating_count updating out of $total_count total nodepools"

		if [[ "$all_ready" == "true" ]]; then
			log "All nodepools finished updating successfully!"
			return 0
		fi

		log "Still waiting for nodepools to finish updating... ($counter/$timeout seconds elapsed, next check in 20s)"
	done

	log "Timeout waiting for nodepools to finish updating after $timeout seconds"
	log "Final nodepool status check:"
	for np in $nodepools; do
		oc get nodepool "$np" -n "$hc_namespace" -o yaml | grep -A5 -B5 "conditions:" || log "Failed to get final status for $np"
	done
	return 1
}

# Patch the HostedCluster with imageContentSources
patch_hosted_cluster() {
	local hc_name="$1"
	local hc_namespace="$2"
	local patch_file="${SHARED_DIR}/idms_patch.json"

	log "Patching HostedCluster $hc_name in namespace $hc_namespace with imageContentSources"

	run "oc patch hostedclusters.hypershift.openshift.io $hc_name -n $hc_namespace --type=merge -p \"\$(cat $patch_file)\""

	log "HostedCluster patched successfully"
}

# Check if IDMS exists on guest cluster
check_idms_on_guest() {
	local guest_kubeconfig="${SHARED_DIR}/nested_kubeconfig"

	if [[ ! -f "$guest_kubeconfig" ]]; then
		log "Guest cluster kubeconfig not found at $guest_kubeconfig"
		return 1
	fi

	log "Checking for IDMS on guest cluster"
	if ! oc --kubeconfig="$guest_kubeconfig" get imagedigestmirrorsets --no-headers 2>/dev/null | grep -q .; then
		log "No IDMS resources found on guest cluster"
		return 1
	fi

	log "Found IDMS resources on guest cluster"
	run "oc --kubeconfig=\"$guest_kubeconfig\" get imagedigestmirrorsets"
	return 0
}

# Check registries.conf on a guest cluster node
check_registries_conf() {
	local guest_kubeconfig="${SHARED_DIR}/nested_kubeconfig"
	local node_name="$1"

	log "Checking /host/etc/containers/registries.conf on node $node_name"

	# Get the registries.conf content for debugging
	local registries_content
	if ! registries_content=$(oc --kubeconfig="$guest_kubeconfig" debug "node/$node_name" -- cat /host/etc/containers/registries.conf 2>&1); then
		log "Failed to read registries.conf from node $node_name: $registries_content"
		return 1
	fi

	log "DEBUG: registries.conf content:"
	echo "$registries_content"
	log "DEBUG: End of registries.conf content"

	# Check for patterns that indicate our mirror configuration
	if echo "$registries_content" | grep -q "quay.io/redhat-user-workloads/ocp-isc-tenant/compliance-operator"; then
		log "registries.conf contains compliance mirror configuration (quay.io pattern found)"
		return 0
	else
		log "registries.conf does not contain expected compliance mirror configuration"
		return 1
	fi
}

# Get a random worker node from guest cluster
get_guest_worker_node() {
	local guest_kubeconfig="${SHARED_DIR}/nested_kubeconfig"

	local worker_node
	worker_node=$(oc --kubeconfig="$guest_kubeconfig" get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | head -1 | awk '{print $1}')

	if [[ -n "$worker_node" ]]; then
		echo "$worker_node"
		return 0
	else
		log "No worker nodes found"
		return 1
	fi
}

# Delete all nodes in guest cluster to force recreation
delete_guest_nodes() {
	local hc_name="$1"
	local hc_namespace="$2"
	local guest_kubeconfig="${SHARED_DIR}/nested_kubeconfig"

	log "WARNING: About to delete all worker nodes. This will cause temporary service disruption."
	local node_count
	node_count=$(oc --kubeconfig="$guest_kubeconfig" get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
	log "Found $node_count worker nodes to delete"
	run "oc --kubeconfig=\"$guest_kubeconfig\" delete nodes -l node-role.kubernetes.io/worker"
}

# Helper function to check IDMS on guest cluster
check_idms_with_retries() {
	local max_retries="$1"
	local retry=0

	while [[ $retry -lt $max_retries ]]; do
		retry=$((retry + 1))
		log "Verification attempt $retry/$max_retries"

		# Check if IDMS exists
		if check_idms_on_guest; then
			# Get a worker node
			local worker_node
			if worker_node=$(get_guest_worker_node); then
				# Check registries.conf
				if check_registries_conf "$worker_node"; then
					log "IDMS successfully propagated and configured on guest cluster"
					return 0
				else
					log "IDMS exists but registries.conf not updated on node $worker_node"
				fi
			else
				log "Could not find worker node to check registries.conf"
			fi
		else
			log "IDMS not found on guest cluster"
		fi

		if [[ $retry -lt $max_retries ]]; then
			log "IDMS verification failed, will retry..."
			sleep 30
		fi
	done

	return 1
}

# Main verification loop - simplified
verify_idms_propagation() {
	local hc_name="$1"
	local hc_namespace="$2"
	local guest_kubeconfig="${SHARED_DIR}/nested_kubeconfig"
	local max_retries=3

	log "Verifying IDMS propagation to guest cluster"
	log "Waiting for IDMS to propagate to guest cluster..."
	sleep 60

	# First attempt
	if check_idms_with_retries "$max_retries"; then
		return 0
	fi

	# If first attempt failed, delete nodes and retry
	log "IDMS verification failed after $max_retries attempts, deleting nodes to force recreation"

	if delete_guest_nodes "$hc_name" "$hc_namespace"; then
		log "Nodes deleted, performing final verification"
		sleep 60
		wait_nodepools_updating "$hc_name" "$hc_namespace" || {
			log "failed to wait the nodepools updating"
			return 1
		}

		# Retry after node recreation
		if check_idms_with_retries "$max_retries"; then
			return 0
		fi
	fi

	log "Error: IDMS verification failed even after node recreation"
	return 1
}

main() {
	log "Updating IDMS for hypershift guest cluster via control plane patch"
 	export KUBECONFIG="${SHARED_DIR}/kubeconfig"
	if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
		export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
	fi
	set_proxy

	run "oc whoami"
	run "oc version -o yaml"

	local hc_name
	hc_name=$(get_hosted_cluster_name) || {
		log "failed to get hosted cluster name"
		return 1
	}

	log "Working with hosted cluster: $hc_name"

	local hc_namespace
	hc_namespace=$(get_hosted_cluster_namespace "$hc_name") || {
		log "failed to get hosted cluster namespace"
		return 1
	}
	log "Hosted cluster namespace: $hc_namespace"

	create_patch_file || {
		log "failed to create patch file"
		return 1
	}

	patch_hosted_cluster "$hc_name" "$hc_namespace" || {
		log "failed to patch hosted cluster"
		return 1
	}

	wait_nodepools_updating "$hc_name" "$hc_namespace" || {
		log "failed to wait the nodepools updating"
		return 1
	}

	verify_idms_propagation "$hc_name" "$hc_namespace" || {
		log "failed to verify IDMS propagation"
		return 1
	}

	log "IDMS update for hypershift guest cluster completed successfully"
}

main
