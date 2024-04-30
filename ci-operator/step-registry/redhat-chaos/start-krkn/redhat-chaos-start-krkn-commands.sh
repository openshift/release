#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x

sleep 30

echo $SHARED_DIR

env | grep SHARED_DIR

echo "START" >> $SHARED_DIR/krkn_start.txt

cat $SHARED_DIR/krkn_start.txt

sleep 1000
