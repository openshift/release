#!/bin/bash

set -eu -o pipefail

declare -r LOGS_DIR="/tmp/test-run-logs"

must_gather() {
    oc get pods -n openshift-operators
    oc describe deployment kepler-operator-controller-manager -n openshift-operators
    oc logs -n openshift-operators deployments/kepler-operator-controller-manager
}

main() {

    mkdir -p $LOGS_DIR
    ./e2e.test -test.v -test.failfast 2>&1 | tee "$LOGS_DIR/e2e.log" || {
        must_gather
        echo "Kepler Operator e2e tests failed !!!"
        exit 1
    }
    echo "Kepler Operator e2e tests passed !!!"
}
main "$@"
