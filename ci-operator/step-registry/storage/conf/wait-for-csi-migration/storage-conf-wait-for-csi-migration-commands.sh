#!/bin/bash
set -o nounset
set -o pipefail

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
                echo "$KCM migrated"
            else
                MIGRATED=false
                echo "$KCM not migrated"
            fi
        done

        # For debugging
        oc -n openshift-kube-controller-manager get pod -l "kube-controller-manager=true" -o yaml &> $ARTIFACT_DIR/kcm-$COUNT.yaml || :

        if $MIGRATED; then
            echo "All KCMs migrated"
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
                echo "$NODE migrated"
            else
                MIGRATED=false
                echo "$NODE not migrated"
            fi
        done

        # For debugging
        oc get csinode -o yaml &> $ARTIFACT_DIR/csinode-$COUNT.yaml || :
        oc get node -o yaml &> $ARTIFACT_DIR/node-$COUNT.yaml || :

        if $MIGRATED; then
            echo "All nodes migrated"
            break
        fi
        COUNT=$[ $COUNT+1 ]
        sleep 5
    done
}

function nodes_stable() {
    # Check that the nodes are Ready
    echo "Checking Nodes Progressing=False"
    oc wait --for=condition=Ready=True node --all --timeout=0 || return 1
    # Check the nodes are schedulable
    echo "Checking Nodes are schedulable"
    if oc get node -o yaml | grep "unschedulable"; then
        return 1
    fi
}

function cluster_stable() {
    echo "Checking ClusterOperators Progressing=False"
    oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=0 || return 1
    echo "Checking ClusterOperators Available=True"
    oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=0 || return 1
    echo "Checking ClusterOperators Degraded=False"
    oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=0 || return 1
}

function wait_for_stable_cluster() {
    # A cluster is considered stable when:
    # - all nodes are Ready
    # - all nodes are schedulable
    # - CVO is Available=true, Progressing=false, Degraded=false
    # - all the checks above are stable for 1 minute
    local COUNT=1
    local STABLE_COUNT=1
    while true; do
        echo
        echo "$(date) Waiting for the cluster to stabilize, attempt $COUNT"

        if nodes_stable ; then
            echo "Nodes are stable"
        else
            STABLE_COUNT=0
            echo "Nodes are not stable"
        fi

        if cluster_stable; then
            echo "Cluster is stable"
        else
            STABLE_COUNT=0
            echo "Cluster is not stable"
        fi

        oc get node -o yaml &> $ARTIFACT_DIR/stability-node-$COUNT.yaml || :
        oc get clusteroperator -o yaml > $ARTIFACT_DIR/stability-clusteroperator-$COUNT.yaml || :

        # Wait until 6 checks pass in a row (at least 1 minute, probably much more)
        if [ "$STABLE_COUNT" -ge "6" ]; then
            echo "Cluster is stable"
            break
        fi
        COUNT=$[ $COUNT+1 ]
        echo "Current stability: $STABLE_COUNT"
        STABLE_COUNT=$[ $STABLE_COUNT+1 ]
        sleep 10
    done
}

wait_for_kcms
wait_for_nodes
wait_for_stable_cluster
