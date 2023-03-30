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
  name: quay-operator
spec:
  package:
    name: quay-operator
EOF

    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc get platformoperator quay-operator -o=jsonpath="{.status.conditions[0].status}"`
        if [[ $STATUS = "True" ]]; then
            echo "create quay operator successfully"
            break
        fi
    done
    if [[ $STATUS != "True" ]]; then
        echo "!!! fail to create quay operator"
        run_command "oc get platformoperator quay-operator -o yaml"
        run_command "oc get pods -n quay-operator-system"

        return 1
    fi
}

set_proxy
create_platform_operator
