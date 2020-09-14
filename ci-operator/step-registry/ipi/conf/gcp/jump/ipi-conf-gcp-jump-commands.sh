#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

case $((RANDOM % 2)) in
0) jump="core@35.243.201.37";;
1) jump="core@35.229.113.67";;
*) echo >&2 "invalid index"; exit 1;;
esac
echo "Jump host : ${jump}"

echo "${jump}" > "${SHARED_DIR}"/jump-host.txt
