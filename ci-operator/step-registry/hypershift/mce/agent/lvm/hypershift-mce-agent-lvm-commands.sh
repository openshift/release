#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

source "${SHARED_DIR}/packet-conf.sh"

cat <<EOF | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      deviceSelector:
      paths:
      - /dev/vda
      default: true
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
EOF

while true; do
    while IFS= read -r line; do
        status=$(echo "$line" | awk '{print $3}')
        if [[ $status != "Running" ]]; then
            echo "Waiting for pods to be running..."
            sleep 10
            continue 2  # Continue the outer loop
        fi
    done < <(oc get pod -n openshift-storage | awk '/(topolvm-node-|vg-manager-)/{print $0}')

    echo "All pods are running."
    break
done

#oc wait lvmcluster -n openshift-storage my-lvmcluster --for=jsonpath='{.status.state}'=Ready --timeout=20m