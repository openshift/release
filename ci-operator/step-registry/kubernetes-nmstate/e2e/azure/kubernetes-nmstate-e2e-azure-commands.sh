#!/bin/bash

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# wait for all clusteroperators to reach progressing=false to ensure that we achieved the configuration specified at installation
# time before we run our e2e tests.
function check_clusteroperators_status() {
    echo "$(date) - waiting for clusteroperators to finish progressing..."
    oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m
    echo "$(date) - all clusteroperators are done progressing."
}

oc wait --for=condition=Progressing=False --timeout=2m clusterversion/version
check_clusteroperators_status

make test-e2e-azure-ocp
