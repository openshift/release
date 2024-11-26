#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")

echo "kubeconfig ..."
echo $KUBECONFIG

ping -c 5 $bastion