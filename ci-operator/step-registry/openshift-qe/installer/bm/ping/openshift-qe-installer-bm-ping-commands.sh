#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")

ping -c 5 10.1.38.49
