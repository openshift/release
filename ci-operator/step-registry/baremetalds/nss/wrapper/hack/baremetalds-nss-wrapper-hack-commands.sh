#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds nss wrapper hack command "************
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

dir=/tmp/secret

if [ ! -d ${dir} ]; then
    echo "Making ${dir}"
    mkdir -p ${dir}
fi

echo "Copying nss artifacts to ${dir}"
cp /bin/mock-nss.sh /usr/lib64/libnss_wrapper.so ${dir}

echo "shared dir test"
touch ${SHARED_DIR}/foo.txt




