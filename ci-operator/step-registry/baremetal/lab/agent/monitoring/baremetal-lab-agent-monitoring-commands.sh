#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

function cleanup() {
  for child in $( jobs -p ); do
    kill "${child}"
  done
}

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

echo "Running monitoring tasks"

echo "Lookup $AUX_HOST"

nslookup $AUX_HOST

echo "Resolve $AUX_HOST hostname using dig"

dig $AUX_HOST

echo "Print resolv.conf"

cat /etc/resolv.conf