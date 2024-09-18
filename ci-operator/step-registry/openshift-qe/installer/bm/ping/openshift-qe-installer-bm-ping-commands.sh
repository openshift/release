#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")

ping -c 5 10.6.66.1
curl 10.6.66.1:22
