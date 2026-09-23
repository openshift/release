#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp add day2 workers optionally command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "${REPO_DIR}" ]; then
  mkdir -p "${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "${REPO_DIR}"
fi

cd "${REPO_DIR}/deploy/operator/ztp/"

echo "### Sourcing root config."

source /root/config

echo "### Injecting ZTP configuration."

# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

echo "### Done injecting ZTP configuration."

function test_node_labels() {
  echo "Info: Testing node labels"
  echo >> /etc/hosts
  echo "192.168.111.85 api.assisted-test-cluster.redhat.com" >> /etc/hosts
  SPOKE_KUBECONFIG=/tmp/spoke_kubeconfig
  oc get -n assisted-spoke-cluster secret assisted-test-cluster-admin-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > $SPOKE_KUBECONFIG || exit 1
  node_roles=$(oc --kubeconfig $SPOKE_KUBECONFIG get node -o json | jq  -c ' [.items | .[] | .metadata.labels | to_entries |
    { ( .[] | select( .key == "kubernetes.io/hostname") | .value ) :
    [ .[] | select( .key | test("node-role.kubernetes.io/") ) | .key | sub( "node-role.kubernetes.io/" ; "" ) ] }] | add')
  for node in "ostest-extraworker-3" "ostest-extraworker-5" ; do
    index=$(echo $node_roles | jq ".\"$node\" | index(\"infra\")")
    if [ "$index" == "null" ] ; then
      echo "Error: expected $node to contain label 'infra'"
      exit 1
    fi
  done
  for node in "ostest-extraworker-0" "ostest-extraworker-1" "ostest-extraworker-2" "ostest-extraworker-4" ; do
    index=$(echo $node_roles | jq ".\"$node\" | index(\"infra\")")
    if [ "$index" != "null" ] ; then
      echo "Error: expected $node to not to contain label 'infra'"
      exit 1
    fi
  done
  machine_count=$(oc --kubeconfig $SPOKE_KUBECONFIG get mcp infra -o jsonpath={.status.machineCount})
  if [ "$machine_count" != "2" ] ; then
    echo "Error: expected 2 machines for infra MCP got $machine_count"
    exit 1
  fi
}
# Only run tests defined in this script

case "$TEST_TO_RUN" in
  "node-labels")
    test_node_labels
  ;;
  "")
    exit 0
    ;;
  *)
    echo "Unknown test $TEST_TO_RUN ..."
    exit 1
    ;;
esac

exit 0
EOF
