#!/bin/bash

set -eu -o pipefail

must_gather() {
    oc get pods -n openshift-operators
    oc describe deployment kepler-operator-controller-manager -n openshift-operators
    oc logs -n openshift-operators deployments/kepler-operator-controller-manager
}

validate_cluster() {
    local label="operators.coreos.com/kepler-operator.openshift-operators"
    local ret=0
    echo "Validating cluster"
    oc get subscriptions -l "$label" -n openshift-operators || {
        echo "Missing subscription. Something wrong with Operator Installation"
        ret=1
    }
    oc get crds | grep kepler || {
        echo "Missing Kepler CRD. Something wrong with Operator Installation"
        ret=1
    }
    oc get clusterrole,clusterrolebindings -l "$label" -A || {
        echo "Missing clusterrole/clusterrolebindings. Something wrong with Operator Installation"
        ret=1
    }
    return $ret
}
deploy_kepler() {
    cat <<EOF | oc apply -f -
    apiVersion: kepler.system.sustainable.computing.io/v1alpha1
    kind: Kepler
    metadata:
        labels:
            app.kubernetes.io/name: kepler
            app.kubernetes.io/instance: kepler
            app.kubernetes.io/part-of: kepler-operator
        name: kepler
    spec:
    exporter:
        port: 9103
EOF

}
main() {
    validate_cluster || {
        must_gather
        return 1
    }
    deploy_kepler || {
        must_gather
        return 1
    }
}
main "$@"
