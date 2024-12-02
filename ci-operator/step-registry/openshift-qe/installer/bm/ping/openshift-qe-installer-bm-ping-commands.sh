#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")

ping -c 5 $bastion

echo "hi" | nc 10.6.60.107 6443
