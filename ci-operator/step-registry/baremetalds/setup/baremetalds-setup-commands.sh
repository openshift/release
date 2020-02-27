#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ setup command ************"
env

echo ""
echo "------------ /tmp"
ls -ll /tmp

echo ""
echo "------------ /tmp/secret-wrapper"
ls -ll /tmp/secret-wrapper

echo ""
echo "------------ ${SHARED_DIR}"
ls -ll ${SHARED_DIR}

echo ""
echo "------------ /usr/local"
ls -ll /usr/local

echo ""
echo "------------ /usr/local/e2e-baremetalds-cluster-profile"
ls -ll /usr/local/e2e-baremetalds-cluster-profile




