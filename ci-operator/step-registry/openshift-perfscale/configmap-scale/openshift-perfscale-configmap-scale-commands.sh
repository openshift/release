#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

pushd /tmp
curl -sSL External link: https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux-amd64-rhel8.tar.gz | tar xz
unset VERSION
export HOME=/tmp
export PATH=${PATH}:/tmp
git clone https://github.com/cloud-bulldozer/cluster-perf-ci --depth=1
sed -i 's/enabled: true/enabled: false/' cluster-perf-ci/configmap-scale.yml
cat cluster-perf-ci/configmap-scale.yml
pushd cluster-perf-ci
./run.sh
