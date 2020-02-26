#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Copying nss artifacts to ${SHARED_DIR}"
cp /bin/mock-nss.sh /usr/lib64/libnss_wrapper.so ${SHARED_DIR}




