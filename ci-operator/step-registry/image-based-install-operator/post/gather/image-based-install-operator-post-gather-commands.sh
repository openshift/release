#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator post gather command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

export ARTIFACT_DIR=/ibio-post-gather
mkdir -p ${ARTIFACT_DIR}
oc get baremetalhost ostest-extraworker-0 -n openshift-machine-api -o yaml > ${ARTIFACT_DIR}/baremetalhost.yaml
# in case of an error in deleting the dataimage, we want to see it
oc get dataimage ostest-extraworker-0 -n openshift-machine-api -o yaml > ${ARTIFACT_DIR}/dataimage.yaml || true
oc get clusterdeployment ibi-cluster -n ibi-cluster -o yaml > ${ARTIFACT_DIR}/clusterdeployment.yaml
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c manager > ${ARTIFACT_DIR}/image-based-install-operator-manager.log
oc logs --tail=-1 -l app=image-based-install-operator -n image-based-install-operator -c server > ${ARTIFACT_DIR}/image-based-install-operator-server.log

EOF

ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /ibio-post-gather | tar -C "${ARTIFACT_DIR}" -xzf -
