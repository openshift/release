#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51095"

# Check set fake uuid, installer should proceed
dir=/tmp/test
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
# shellcheck source=/dev/null
source "${SHARED_DIR}/nutanix_context.sh"
sed -i "s/${PE_UUID}/fake-uuid/g" "${dir}/install-config.yaml"

set +e
output=$(openshift-install --dir=${dir} create manifests 2>&1)
set -e

if echo "$output" | grep "Invalid UUID passed"; then
    echo "Pass: check set fake prismElements uuid"
else
    echo "Fail: check set fake prismElements uuid"
    exit 1
fi

if [ -d "${dir}"/openshift ]; then
    echo "Pass: check installer should proceed"
else
    echo "Fail: check installer should proceed"
    exit 1
fi

# Restore
rm -rf "${dir}"
