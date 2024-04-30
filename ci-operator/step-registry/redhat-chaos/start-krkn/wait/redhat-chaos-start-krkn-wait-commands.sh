#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x

echo $SHARED_DIR

env | grep SHARED_DIR
cat $SHARED_DIR/krkn_start.txt

sleep 1000



sleep 1000
