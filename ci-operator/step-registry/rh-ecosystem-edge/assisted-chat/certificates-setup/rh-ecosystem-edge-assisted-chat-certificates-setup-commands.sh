#!/bin/bash

set -eu

last_approved_ts=$(date +%s)

while true; do
    # Give a good chance for CSRs to appear after approving others
    (($(date +%s) - last_approved_ts > 180)) && break

    for csr in $(oc get csr -o json | jq -r '
    .items[]
    | select(
        ((.status.conditions // [])
         | any(.type == "Approved" and .status == "True")
        )
        | not
      )
    | .metadata.name
  '); do
        if ! oc adm certificate approve "$csr"; then
            echo "failed to approve $csr" >&2
            continue
        fi
        last_approved_ts=$(date +%s)
    done

    sleep 3
done
