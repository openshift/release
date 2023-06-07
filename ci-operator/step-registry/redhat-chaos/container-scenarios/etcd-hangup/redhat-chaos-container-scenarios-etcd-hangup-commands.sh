#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
pushd /tmp

ls -la /root/kraken
git clone https://github.com/redhat-chaos/krkn-hub.git
pushd krkn-hub/

echo "kubeconfig loc $$KUBECONFIG"

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE
export ENABLE_ALERTS=False
./prow/container-scenarios/prow_run.sh
rc=$?
echo "Finished running container scenarios"
echo "Return code: $rc"
