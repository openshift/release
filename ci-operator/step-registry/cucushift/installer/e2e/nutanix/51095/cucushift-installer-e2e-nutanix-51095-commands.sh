#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51095"
dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

## Check set fake uuid, installer should proceed
sed -i "s/uuid: 0005d9a4-8e4f-7c33-58d1-e9d0e2d48853/uuid: fake-uuid/g" "${SHARED_DIR}/install-config.yaml"
if openshift-install --dir="${dir}" create manifests 2>&1 | grep "Invalid UUID passed"; then
    echo "Pass: check set fake prismElements uuid"
else
    echo "Fail: check set fake prismElements uuid"
fi

if [ -d "${dir}"/openshift ]; then
    echo "Pass: check installer should proceed"
else
    echo "Fail: check installer should proceed"
fi

## Restore
rm -rf "${dir}"
