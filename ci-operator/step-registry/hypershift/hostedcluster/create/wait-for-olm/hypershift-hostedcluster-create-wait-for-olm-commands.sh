#!/usr/bin/env bash
set -euo pipefail

if [[ "${WAIT_FOR_OLM:-false}" == "false" ]]; then
  echo "Skipping waiting for OLM to be ready"
  exit 0
fi

echo "$(date) Start to wait for OLM to be ready..."
echo My username is: "$(oc whoami)"

echo "Waiting for OLM to be come available"
START_TIME=$(date +%s)
for _ in {1..100}; do
  num_of_packagemanifests=`oc get packagemanifests -n openshift-marketplace | wc -l`
  if [[ $num_of_packagemanifests -gt 1 ]]; then
    break
  else
    echo "No packagemanifests yet, waiting 15s"
    sleep 15
  fi
done
END_TIME=$(date +%s)
echo "$(date) Completed."

if [[ $num_of_packagemanifests -lt 1 ]]; then
  echo "Still no packagemanifests available."
  exit 1
fi

echo "OLM is ready in $((END_TIME - START_TIME)) seconds"
