#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG...."
echo $SHARED_DIR
ls -al $SHARED_DIR
echo "DEBUG --1--"
date > $SHARED_DIR/DATE
echo "DEBUG --2--"
uname -a
cat /etc/hostname
echo "DEBUG --3--"
ls -l /dev
echo "DEBUG --4--"
ls -l /dev/disk || true
echo "DEBUG --5--"
ls -l /dev/disk/by-id || true
echo "DEBUG --6--"
