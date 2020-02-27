#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

env

dir=/tmp/shared
mkdir "${dir}/"

echo "Copying nss artifacts to ${dir}"
cp /bin/mock-nss.sh /usr/lib64/libnss_wrapper.so ${dir}




