#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

function info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function wait_for_cpms_done() {
  if
    ! oc wait --timeout=90m --for=condition=Progressing=false controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.spec.replicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.status.updatedReplicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.status.replicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null || \
    ! oc wait --timeout=90m --for=jsonpath='{.status.readyReplicas}'=3 controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster 1>/dev/null; then
      info "CPMS not scaled to 3 replicas"
      oc get controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster
      oc describe controlplanemachineset.machine.openshift.io cluster --namespace openshift-machine-api
      exit 1
  else
    info 'CPMS scaled the masters.'
    oc get controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster
    oc describe controlplanemachineset.machine.openshift.io cluster --namespace openshift-machine-api
  fi
  info "Done waiting for CPMS to scale the masters."
}

info "Detected the environment variable SCALE_MASTERS_FLAVOR_ALTERNATE set to '$SCALE_MASTERS_FLAVOR_ALTERNATE'. Patching the CPMS..."
patch="$(printf '{"spec":{"template":{"machines_v1beta1_machine_openshift_io":{"spec":{"providerSpec":{"value":{"flavor":"%s"}}}}}}}' "$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE")")"
oc patch controlplanemachineset.machine.openshift.io --type=merge --namespace openshift-machine-api cluster -p "$patch"

info "Sleeping for 10 seconds..."
sleep 10

info 'Waiting 5 minutes for the CPMS operator to pick up the edit...'
oc wait --timeout=5m --for=condition=Progressing=true controlplanemachineset.machine.openshift.io -n openshift-machine-api cluster

wait_for_cpms_done

info 'Waiting for clusteroperators to finish progressing...'
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=30m

info 'Done.'
