#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ setup command ************"
env

echo "------------ /tmp"
ls -ll /tmp

echo "------------ /tmp/cluster"
ls -ll /tmp/cluster



