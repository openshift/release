#!/bin/bash

# Extract and format the cluster version
get_cluster_version() {
  version=$(oc version | grep "Server Version:" | awk '{print $3}')
  major=$(echo "$version" | cut -d '.' -f 1)
  minor=$(echo "$version" | cut -d '.' -f 2)
  echo "$major.$minor"
}

# greater that function for versions
version_greater_than() {
  [[ "$(printf "%s\n%s\n" "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]
}

cluster_version=$(get_cluster_version)
KREW_REQUIRED_VERSION_THRESHOLD="4.18"
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
if version_greater_than "$cluster_version" "$latest_release_version"; then
  testing_branch="main"
fi
git checkout ${testing_branch}

# if cluster verion greater than threshold, install Krew and the commatrix-krew plugin
if version_greater_than "$cluster_version" "$KREW_REQUIRED_VERSION_THRESHOLD"; then
  # Install krew
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/arm/')"
  KREW="krew-${OS}_${ARCH}"
  mkdir -p ${SHARED_DIR}/krew
  curl -fsSL "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" -o "${SHARED_DIR}/krew/${KREW}.tar.gz"
  tar -xvzf ${SHARED_DIR}/krew/${KREW}.tar.gz -C ${SHARED_DIR}/krew
  ${SHARED_DIR}/krew/${KREW} install krew
  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"  
  # install commatrix-krew plugin
  oc krew install --manifest=cmd/commatrix-krew.yaml
  # cleanUP
  rm -rf "${SHARED_DIR}/krew"
fi

go mod vendor
EXTRA_NFTABLES_MASTER_FILE="${ADDITIONAL_NFTABLES_RULES_FILE_PATH}" EXTRA_NFTABLES_WORKER_FILE="${ADDITIONAL_NFTABLES_RULES_FILE_PATH}" SUITE="${SUITE}" \
OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FILE="${OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FILE}" OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FORMAT="${OPEN_PORTS_TO_IGNORE_IN_DOC_TEST_FORMAT}" make e2e-test
popd || exit
