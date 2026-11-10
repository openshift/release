#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator post delete ici command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

source /root/env.sh

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

echo "### Delete the ImageClusterInstall"
oc delete imageclusterinstall ibi-cluster -n ibi-cluster
oc wait -n ibi-cluster --for=delete imageclusterinstalls.extensions.hive.openshift.io/ibi-cluster --timeout=10m
oc wait -n openshift-machine-api --for=delete dataimages.metal3.io/ostest-extraworker-0 --timeout=20m

echo "### Removing the config iso includes rebooting ibi-host, waiting for ibi-cluster to come back up"
timeout 10m bash -c 'until oc --kubeconfig /root/ibi-cluster/kubeconfig get clusterversion,clusteroperators; do sleep 5; done'

EOF
