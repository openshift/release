#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

ping -c 5 10.26.8.107
echo "hi" | nc -w 10.26.8.107 443
echo $?