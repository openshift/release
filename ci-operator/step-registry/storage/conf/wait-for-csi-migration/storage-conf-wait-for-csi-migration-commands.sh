#!/bin/bash
set -o nounset
set -o pipefail

set -x

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}

function list_kcms() {
    # Tolerate errors from API server. Nodes and kube-controller-manager are restarted during this process.
    while true; do
        oc -n openshift-kube-controller-manager get pod -l "kube-controller-manager=true" -o custom-columns=NAME:.metadata.name --no-headers && break
    done
}

function kcm_migrated {
    local POD=$1

    # This will return 0 when the migration is enabled in the KCM pod.
    # Any API server failure results in nozero exit code, i.e. not migrated KCM.
    oc -n openshift-kube-controller-manager get pod $POD -o custom-columns=NAME:.spec.containers[0].args --no-headers  | fgrep -- "--feature-gates=CSIMigrationAWS=true" > /dev/null
}

function wait_for_kcms() {
    local COUNT=1

    while true; do
        local MIGRATED=true
        echo "$(date) waiting for all kube-controller-managers migrated, attempt $COUNT"

        for KCM in $( list_kcms ); do
            if kcm_migrated $KCM; then
                echo $KCM migrated
            else
                MIGRATED=false
                echo $KCM not migrated
            fi
        done

        # For debugging
        oc -n openshift-kube-controller-manager get pod -l "kube-controller-manager=true" -o yaml &> $ARTIFACT_DIR/kcm-$COUNT.yaml || :

        if $MIGRATED; then
            echo All KCMs migrated
            break
        fi
        COUNT=$[ $COUNT+1 ]
        sleep 5
    done
}

function list_nodes() {
    # Tolerate errors from API server. Nodes and kube-controller-manager are restarted during this process.
    while true; do
        oc get node -o custom-columns=NAME:.metadata.name --no-headers && break
    done
}

function node_migrated {
    local NODE=$1

    # This will return 0 when the migration is enabled in the node. Using AWS just as one representative,
    # all plugins should be migrated.
    # Any API server failure results in nozero exit code, i.e. not migrated node.
    oc get csinode $NODE -o yaml | grep -- "storage.alpha.kubernetes.io/migrated-plugins:.*kubernetes.io/aws-ebs" > /dev/null
}

function wait_for_nodes() {
    local COUNT=1

    while true; do
        local MIGRATED=true
        echo "$(date) waiting for all nodes migrated, attempt $COUNT"

        for NODE in $( list_nodes ); do
            if node_migrated $NODE; then
                echo $NODE migrated
            else
                MIGRATED=false
                echo $NODE not migrated
            fi
        done

        # For debugging
        oc get csinode -o yaml &> $ARTIFACT_DIR/csinode-$COUNT.yaml || :
        oc get node -o yaml &> $ARTIFACT_DIR/node-$COUNT.yaml || :

        if $MIGRATED; then
            echo All nodes migrated
            break
        fi
        COUNT=$[ $COUNT+1 ]
        sleep 5
    done
}

wait_for_kcms
wait_for_nodes
