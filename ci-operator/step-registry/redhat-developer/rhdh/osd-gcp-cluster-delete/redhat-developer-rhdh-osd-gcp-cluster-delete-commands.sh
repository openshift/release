#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64


echo "delete cluster : "
echo "ocm version:"
ocm version
echo "oc version:"
oc version
