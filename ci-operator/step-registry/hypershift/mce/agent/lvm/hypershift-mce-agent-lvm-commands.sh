#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

source "${SHARED_DIR}/packet-conf.sh"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
output=\$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for ip_worker in \${output}; do
    ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa core@\$ip_worker "sudo mkfs.ext4 /dev/vda; sudo wipefs -a /dev/vda"
done
EOF

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