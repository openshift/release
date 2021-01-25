#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Leased resource is ${LEASED_RESOURCE}"

export PATH=$PATH:/tmp/bin
mkdir /tmp/bin

echo "$(date -u --rfc-3339=seconds) - Installing tools..."

cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

echo Performing chaos action on $cluster_name

echo "$(date -u --rfc-3339=seconds) - Collecting vCenter performance data, events, and alerts"

set +e
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"

echo Checking cluster at $vm_path
govc ls 

# install sonobuoy
# TODO move to image
# curl -L https://github.com/vmware/govmomi/releases/download/v0.24.0/govc_linux_amd64.gz | tar xvzf - -C /tmp/bin/ govc
# chmod ug+x /tmp/bin/govc
# govc version

# install jq
# TODO move to image
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
chmod ug+x /tmp/bin/jq
jq

# install yq
# TODO move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 > /tmp/bin/yq 
chmod ug+x /tmp/bin/yq
yq --version


