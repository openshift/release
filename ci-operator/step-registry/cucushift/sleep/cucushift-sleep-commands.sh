#!/bin/sh

TIMEOUT=${TIMEOUT:-12h}
echo "This step will wait for ${TIMEOUT}.
  You can kill the main pod process executing this script to proceed with the cluster deprovisioning steps."
sleep "$TIMEOUT"

