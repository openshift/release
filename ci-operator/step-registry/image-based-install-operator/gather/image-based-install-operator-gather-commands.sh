#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator gather command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

mkdir /root/ibio-gather
oc get baremetalhost ostest-extraworker-0 -n openshift-machine-api -o yaml > /root/ibio-gather/baremetalhost.yaml
oc get clusterdeployment ibi-cluster -n ibi-cluster -o yaml > /root/ibio-gather/clusterdeployment.yaml
oc get imageclusterinstall ibi-cluster -n ibi-cluster -o yaml > /root/ibio-gather/imageclusterinstall.yaml
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c manager > /root/ibio-gather/image-based-install-operator-manager.logs
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c server > /root/ibio-gather/image-based-install-operator-server.logs

EOF

ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /root/ibio-gather | tar -C "${ARTIFACT_DIR}" -xzf -