#!/bin/bash
if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    sleep "$SLEEP_DURATION" &
    wait
else
    echo "exit without kubeconfig"
fi