#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Determine the effective cluster type, matching the logic in
# openstack-conf-clouds.
[[ "${LEASED_RESOURCE:-}" == openstack* ]] && CLUSTER_TYPE="${LEASED_RESOURCE}"
CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"

# Auto-enable for cloud profiles affected by the Ceph RGW / Swift
# TempURL key mismatch (the driver selects container-level keys but
# RGW validates against account-level keys, producing HTTP 403).
# Workaround for OCPBUGS-128588.
if [[ "${OPENSTACK_DISABLE_REGISTRY_REDIRECT:-}" != "true" ]]; then
	case "${CLUSTER_TYPE}" in
		openstack-vexxhost)
			echo "Auto-enabling disableRedirect for ${CLUSTER_TYPE} (Ceph RGW TempURL workaround)."
			;;
		*)
			echo "OPENSTACK_DISABLE_REGISTRY_REDIRECT is not set and ${CLUSTER_TYPE} is not affected. Skipping."
			exit 0
			;;
	esac
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server.
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Patching image registry to disable redirect (TempURL)..."
oc patch configs.imageregistry.operator.openshift.io cluster \
	--type merge -p '{"spec":{"disableRedirect":true}}'

echo "Waiting for image-registry operator to reconcile..."
sleep 5
oc wait --timeout=5m --for=condition=Progressing=false \
	clusteroperator/image-registry

echo "Done. The image registry will now proxy blob data instead of redirecting to Swift TempURLs."
