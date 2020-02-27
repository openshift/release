#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nss wrapper hack command "************
env

dir=/tmp/secret

if [ ! -d ${dir} ]; then
    echo "Making ${dir}"
    mkdir -p ${dir}
fi

echo "Copying nss artifacts to ${dir}"
cp /bin/mock-nss.sh /usr/lib64/libnss_wrapper.so ${dir}

echo ""
echo "------------ /${SHARED_DIR}"
ls -ll ${SHARED_DIR}

echo ""
echo "------------ /tmp/secret"
ls -ll /tmp/secret





