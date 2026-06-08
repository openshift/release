#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

image_name="$(cat "${SHARED_DIR}/preload-image-name.txt")"

check_key_words='Using the existing rhcos image \"'$image_name'\" in PC'
if grep -F "${check_key_words}" "${SHARED_DIR}"/nutanix-preload-image-openshift_install.log; then
    echo "Pass: passed to check install with preload image"
else
    echo "Fail: failed to check install with preload image"
    check_result=1
fi

exit "${check_result}"
