#!/bin/bash
#
# This script mocks prow behaviour so you should be able to run PR test locally. 

if [[ $# -ne 2  ]]; then
    echo error: $0 tags/ref resource_group_name
    exit 1
fi

SOURCE=$1
export RESOURCEGROUP=$2

set +x
source  /usr/secrets/secret
export AZURE_AAD_CLIENT_ID=$AZURE_CLIENT_ID
export AZURE_AAD_CLIENT_SECRET=$AZURE_CLIENT_SECRET
set -x
export DNS_DOMAIN=osadev.cloud
export DNS_RESOURCEGROUP=dns
export DEPLOY_VERSION=v3.11
export NO_WAIT=true
export RUNNING_UNDER_TEST=true

az login --service-principal -u ${AZURE_CLIENT_ID} -p ${AZURE_CLIENT_SECRET} --tenant ${AZURE_TENANT_ID} &>/dev/null

T1="$(mktemp -d)"
export GOPATH="${T1}"
mkdir -p "${T1}/src/github.com/openshift/"
cd "${T1}/src/github.com/openshift/"
git clone https://github.com/openshift/openshift-azure 
cd openshift-azure
git checkout $SOURCE
# link shared secrets
ln -s /usr/secrets ${T1}/src/github.com/openshift/openshift-azure/secrets
echo "Source cluster source code location:"
echo "${T1}/src/github.com/openshift/"
make create

# because we use host dir mounted, we make copy of the code
# this is because UID/GID
echo "If you want to switch to master branch and start upgrade, execute"
echo "
T2="$(mktemp -d)"
export GOPATH="${T2}"
mkdir -p "${T2}/src/github.com/openshift/"
cd "${T2}/src/github.com/openshift/"
# silent error for RO files in _data
cp -r /go/src/github.com/openshift/openshift-azure ${T2}/src/github.com/openshift/ 2>/dev/null || :
cp -r ${T1}/src/github.com/openshift/openshift-azure/_data ${T2}/src/github.com/openshift/openshift-azure/ 2>/dev/null || :
cd ${T2}/src/github.com/openshift/openshift-azure
./hack/upgrade.sh
"

