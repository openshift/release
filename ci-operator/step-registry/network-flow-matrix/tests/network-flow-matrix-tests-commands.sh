#!/bin/bash

# Extract and format the cluster version
get_cluster_version() {
  version=$(oc version | grep "Server Version:" | awk '{print $3}')
  major=$(echo "$version" | cut -d '.' -f 1)
  minor=$(echo "$version" | cut -d '.' -f 2)
  echo "$major.$minor"
}
cluster_version=$(get_cluster_version)

ADDITIONAL_NFTABLES_RULES_FILE_PATH="${SHARED_DIR}/additional-nftables-rules"
SUITE=${SUITE:-"all"}

echo "# Allow host level services dynamic port range
tcp dport 9000-9999 accept
udp dport 9000-9999 accept
# Allow Kubernetes node ports dynamic port range
tcp dport 30000-32767 accept
udp dport 30000-32767 accept
# Keep port open for origin test
# https://github.com/openshift/origin/blob/master/vendor/k8s.io/kubernetes/test/e2e/network/service.go#L2622
tcp dport 10180 accept
udp dport 10180 accept
# Keep port open for origin test
# https://github.com/openshift/origin/blob/master/vendor/k8s.io/kubernetes/test/e2e/network/service.go#L2724
tcp dport 80 accept
udp dport 80 accept" > ${ADDITIONAL_NFTABLES_RULES_FILE_PATH}

source $HOME/golang-1.22.4
echo "Go version: $(go version)"
git clone https://github.com/openshift-kni/commatrix ${SHARED_DIR}/commatrix
pushd ${SHARED_DIR}/commatrix || exit

latest_release_version="$(git branch -r | grep -oE 'release-[0-9]+\.[0-9]+' | sed 's/release-//' | sort -V | tail -1)"
testing_branch="release-$cluster_version"

# If cluster's version is greater than latest release version, use main as testing branch.
if [[ "$(printf "%s\n%s\n" "$cluster_version" "$latest_release_version" | sort -V | tail -1)" == "$cluster_version" && "$cluster_version" != "$latest_release_version" ]]; then
  testing_branch="main"
fi

git checkout ${testing_branch}
go mod vendor
EXTRA_NFTABLES_MASTER_FILE="${ADDITIONAL_NFTABLES_RULES_FILE_PATH}" EXTRA_NFTABLES_WORKER_FILE="${ADDITIONAL_NFTABLES_RULES_FILE_PATH}" SUITE="${SUITE}" \
OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FILE="${OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FILE}" OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FORMAT="${OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FORMAT}" make e2e-test
popd || exit
