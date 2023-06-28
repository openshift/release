#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -z "$SCALE_MASTERS_FLAVOR_ALTERNATE" ]; then
	info "All defined environment variables for the step are empty. Exiting."
	exit 0
fi

declare patch=''

info "Detected the environment variable SCALE_MASTERS_FLAVOR_ALTERNATE set to '$SCALE_MASTERS_FLAVOR_ALTERNATE'. Patching the CPMS..."
patch="$(printf '{"spec":{"template":{"machines_v1beta1_machine_openshift_io":{"spec":{"providerSpec":{"value":{"flavor":"%s"}}}}}}}' "$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE")")"
oc patch controlplanemachineset.machine.openshift.io --type=merge --namespace openshift-machine-api cluster -p "$patch"
sleep 10

info 'Waiting 10 minutes for the CPMS operator to pick up the edit...'
oc wait --timeout=10m --for=condition=Progressing=true controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster

info 'Waiting for the rollout to complete...'
# shellcheck disable=SC2046
oc wait --timeout=90m --for=condition=Progressing=false --for=jsonpath='{.spec.replicas}'=3 --for=jsonpath='{.status.updatedReplicas}'=3 --for=jsonpath='{.status.replicas}'=3 --for=jsonpath='{.status.readyReplicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster -o template='{{.metadata.name}} is ready
'

info 'Done.'
