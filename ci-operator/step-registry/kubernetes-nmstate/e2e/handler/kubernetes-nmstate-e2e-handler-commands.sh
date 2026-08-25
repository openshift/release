#!/bin/bash

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# On disconnected/Internal-publish clusters the API is only reachable via the bastion
# egress proxy. Sourcing proxy-conf.sh is a no-op on connected (e.g. bare-metal) jobs.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# wait for all clusteroperators to reach progressing=false to ensure that we achieved the configuration specified at installation
# time before we run our e2e tests.
function check_clusteroperators_status() {
    echo "$(date) - waiting for clusteroperators to finish progressing..."
    oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
    echo "$(date) - all clusteroperators are done progressing."
}

# (mko) Devscripts makes sure that by the time we are given a cluster, it has been installed correctly.
#       One of those steps is to make sure clusteroperators are stable. So there is no need to check
#       it once again.
#oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version
#check_clusteroperators_status

make test-e2e-handler-ocp
