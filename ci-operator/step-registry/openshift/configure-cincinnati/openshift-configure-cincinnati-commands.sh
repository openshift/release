#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Setting the cluster to Cincinnati instance: $CINCINNATI_URL"
oc patch clusterversion version --patch '{"spec":{"upstream":"'"$CINCINNATI_URL"'"}}' --type=merge

if [[ ! "$CHANGE_CHANNEL_BASE" =~ (stable|eus|fast|candidate) ]]; then
    echo "CHANGE_CHANNEL_BASE is '$CHANGE_CHANNEL_BASE' which is not one of stable, eus, fast, or candidate. Skipping channel update."
    exit
fi

current_channel="$(oc get clusterversion version -o jsonpath='{.spec.channel}')"
if [[ "$current_channel" =~ (stable|eus|fast|candidate)-4\.([0-9]+) ]]; then
    echo "Cluster is subscribed to channel: $current_channel"
    desired_channel="${current_channel//${BASH_REMATCH[1]}/$CHANGE_CHANNEL_BASE}"
    echo "Setting the cluster to use channel: $desired_channel instead of $current_channel"
    oc adm upgrade channel "$desired_channel"
else
    echo "Cluster is subscribed to '$current_channel' which is not a known version channel (stable|eus|fast|candidate)-4.Y. Skipping channel update."
fi
