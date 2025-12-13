#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

sleep 3600

bastion=$(cat "/secret/address")

ping -c 5 $bastion
