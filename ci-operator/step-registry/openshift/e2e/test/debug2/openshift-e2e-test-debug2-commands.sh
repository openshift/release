#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG2....."
oc get no
echo "DEBUG2 --0--"
echo $SHARED_DIR
ls -al $SHARED_DIR
echo "DEBUG2 --1--"
cat $SHARED_DIR/DATE
echo "DEBUG2 --2--"
uname -a
cat /etc/hostname
echo "DEBUG2 --3--"
ls -l /dev
echo "DEBUG2 --4--"
ls -l /dev/disk || true
echo "DEBUG2 --5--"
ls -l /dev/disk/by-id || true
echo "DEBUG2 --6--"
