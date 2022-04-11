#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#shellcheck source=${SHARED_DIR}/runtime_env
#. .${SHARED_DIR}/runtime_env

oc version 
go version
oc get node

echo  -e "Start dr test cases execution:\n"
git clone https://github.com/openshift-qe/ocp-dr-testing.git
echo -e "PWD:" 
pwd
cd ocp-dr-testing/test
echo -e "ls ocp-dr-testing/test:\n"
go test util.go testcase_test.go -v
