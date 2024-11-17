#!/bin/bash

source $HOME/golang-1.22.4
echo "Go version: $(go version)"
git clone https://github.com/openshift-kni/commatrix ${SHARED_DIR}/commatrix
pushd ${SHARED_DIR}/commatrix || exit
git checkout machine-config-test-release
go mod vendor
make e2e-test
popd || exit
