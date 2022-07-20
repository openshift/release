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

# tmp hack to test vsphere
sed -i 's/\[\ \"\${CI}\"\ \=\=\ \"true\"\ \]/\[\ \"\${CI}\"\ \=\=\ \"true\"\ \]\ \&\&\ \[\ \-f\ \${SHARED\_DIR}\/fix\-uid\.sh\ \]/g' hack/ocp-e2e-tests-handler.sh
sed -i 's/enp1s0/ens192/g' hack/ocp-e2e-tests-handler.sh
sed -i 's/enp2s0/ens192/g' hack/ocp-e2e-tests-handler.sh

make test-e2e-handler-ocp
