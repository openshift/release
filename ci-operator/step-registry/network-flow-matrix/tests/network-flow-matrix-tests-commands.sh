#!/bin/bash

# Extract and format the cluster version to branch
cluster_version_to_branch() {
  version=$(oc version | grep "Server Version:" | awk '{print $3}')
  major=$(echo "$version" | cut -d '.' -f 1)
  minor=$(echo "$version" | cut -d '.' -f 2)
  branch="release-$major.$minor"
  echo "$branch"
}
BRANCH=$(cluster_version_to_branch)

source $HOME/golang-1.22.4
echo "Go version: $(go version)"
git clone https://github.com/openshift-kni/commatrix ${SHARED_DIR}/commatrix
pushd ${SHARED_DIR}/commatrix || exit
git checkout ${BRANCH}
go mod vendor
make e2e-test
popd || exit
