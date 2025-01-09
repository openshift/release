#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")
cnv_bastion=$(cat "/secret/cnv_address")

# ping -c 5 $bastion
ping -c 5 $cnv_bastion