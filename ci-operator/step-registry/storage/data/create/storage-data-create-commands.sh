#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}
export NAMESPACE="storage-data"
STORAGE_WORKLOAD_COUNT=${STORAGE_WORKLOAD_COUNT:-50}

export MAX_STEPS=10

create_namespace() {
    local STEPS=$MAX_STEPS

    while ! oc create namespace $NAMESPACE; do
        STEPS=$[ $STEPS - 1]
        if [ "$STEPS" == "0" ]; then
            echo "Failed to create project $NAMESPACE after $MAX_STEPS attempts"
            exit 1
        fi
        sleep 10
    done
    echo "Created namespace $NAMESPACE"
}

create_data() {
    local NAME=$1
    local STEPS=$MAX_STEPS

    while true; do
        oc apply -f - << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $1
  namespace: $NAMESPACE
spec:
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: $NAME
  serviceName: $NAME
  replicas: 1
  template:
    metadata:
      labels:
        app: $NAME
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - resources:
          requests :
            cpu: 1m
        image: quay.io/centos/centos:8
        command:
          - "sleep"
          - "999999999"
        name: centos
        volumeMounts:
          - name: data
            mountPath: /mnt/test
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 50Mi
EOF
        if [ "$?" == "0" ]; then
            return
        fi

        STEPS=$[ $STEPS - 1]
        if [ "$STEPS" == "0" ]; then
            echo "Failed to create StatefulSet $NAME after $MAX_STEPS attempts"
            exit 1
        fi
        sleep 10
    done

    echo "Created data $NAME"
}

save_data() {
    local NAME=$1
    local PODNAME="$NAME-0"
    local STEPS=$MAX_STEPS

    while ! oc exec -n $NAMESPACE $PODNAME -- sh -c "echo initial data > /mnt/test/data"; do
        STEPS=$[ $STEPS - 1]
        if [ "$STEPS" == "0" ]; then
            echo "Failed to save data to pod $PODNAME after $MAX_STEPS attempts"
            exit 1
        fi
        sleep 10
    done
    echo "Data saved in pod $PODNAME"
}


create_namespace

for I in `seq $STORAGE_WORKLOAD_COUNT`; do
    create_data "test-$I"
done

for I in `seq $STORAGE_WORKLOAD_COUNT`; do
    save_data "test-$I"
done

echo "Saving namespace $NAMESPACE in job artifacts for debugging"
oc adm inspect ns/$NAMESPACE --dest-dir="$ARTIFACT_DIR/inspect-$NAMESPACE" || :

exit 0
