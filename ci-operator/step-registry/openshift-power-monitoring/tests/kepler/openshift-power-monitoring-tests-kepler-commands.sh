#!/bin/bash

set -eu -o pipefail

must_gather() {
    oc get pods -n openshift-operators
    oc describe deployment kepler-operator-controller-manager -n openshift-operators
    oc logs -n openshift-operators deployments/kepler-operator-controller-manager
    oc get pods -n openshift-kepler-operator
    oc describe daemonsets/kepler-exporter-ds -n openshift-kepler-operator
    oc logs -n daemonsets/kepler-exporter-ds -n openshift-kepler-operator
}
validate_kepler() {
    local ret=0
    echo "Validating Kepler"
    oc get kepler kepler || {
        echo "Missing Kepler Instance. Something wrong with Kepler deployment"
        ret=1
    }
    oc rollout status -n openshift-kepler-operator daemonset kepler-exporter-ds || {
        echo "Daemonset not in healthy state"
        ret=1
    }
    return $ret
}
main() {
    # below validation steps will be replaced by go tests in future
    validate_kepler || {
        must_gather
        return 1
    }
    sleep 60
    oc expose service/kepler-exporter-svc -n openshift-kepler-operator --name kepler-metrics-route
    url=http://$(oc get route kepler-metrics-route -n openshift-kepler-operator -o jsonpath='{.spec.host}')/metrics
    [[ $(curl "$url" | grep -c kepler_) -gt 0 ]] || {
        echo "Kepler validation failed"
        must_gather
        return 1
    }
    echo "Kepler validation successful"
}
main "$@"
