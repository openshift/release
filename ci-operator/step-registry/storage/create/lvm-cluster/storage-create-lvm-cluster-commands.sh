#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

if test -f "${SHARED_DIR}/packet-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/packet-conf.sh"
fi

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
      - ${LVM_CLUSTER_DEVICE_PATH}
      default: true
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
EOF

echo "Create lvmcluster successfully, waiting for it becomes ready(max 10min)."
iter=10
period=60
result=""
while [[ "${result}" != "Ready" && ${iter} -gt 0 ]]; do
  result=$(oc get lvmcluster -n openshift-storage -o=jsonpath='{.items[0].status.state}')
  (( iter -- ))
  sleep $period
done
if [ "${result}" == "Ready" ]; then
  echo "Set up lvm cluster successfully."
else
  echo "Failed to set up lvm cluster."
  oc describe lvmcluster -n openshift-storage
  for pod in $(oc get pods -n openshift-storage --no-headers | grep -Ev "Running|Completed" | awk '{print $1}')
  do
    echo "This is describe info of pod ${pod}"
    oc -n openshift-storage describe pod "${pod}"
  done
  exit 1
fi
