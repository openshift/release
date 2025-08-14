#!/bin/bash

set -eu

while true; do
    CSR=$(oc get csr | awk '/Pending/ {print $1}')
    if [ -z "$CSR" ]; then
        echo "No CSR to approve, exiting..."
        break
    fi
    oc adm certificate approve $CSR
    sleep 10
done
