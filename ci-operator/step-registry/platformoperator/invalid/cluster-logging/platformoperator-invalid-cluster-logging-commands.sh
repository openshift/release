#!/bin/bash
set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function create_platform_operator() {
    ret=0
    run_command "oc get platformoperator" || ret=$?
    if [[ $ret -ne 0 ]]; then
        echo "Platform Operator feature disabled!"
        return 1
    fi
    cat <<EOF | oc create -f -
---
apiVersion: platform.openshift.io/v1alpha1
kind: PlatformOperator
metadata:
  name: logging-po
spec:
  package:
    name: cluster-logging
EOF

    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        MSG=`oc get platformoperator logging-po -o=jsonpath="{.status.conditions[0].message}"`
        if [[ $MSG =~ "AllNamespace install mode must be enabled" ]]; then
            echo "Cluster logging operator failed to create as expected"
            break
        fi
    done
    if [[ ! $MSG =~ "AllNamespace install mode must be enabled" ]]; then
        echo "!!! Cluster logging operator failed not as expected"
        run_command "oc get platformoperator logging-po -o yaml"

        return 1
    fi
}

set_proxy
create_platform_operator
