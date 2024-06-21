#!/usr/bin/env bash

export KUBECONFIG

echo "Checking if any CSR's need approval"

# polling for 10 minutes, since there can be more CSR's after initial approval
for (( i = 0; i < 5; i++ )); do
  pending_csrs=$(oc get csr | grep Pending | awk '{print $1}')
  if [ -n "$pending_csrs" ]; then
    for csr in $pending_csrs; do
      echo "Approving CSR: $csr"
      oc adm certificate approve "$csr"
    done
    echo "Pending CSRs approved. Checking for more..."
  fi
  echo "No more pending CSRs found. Waiting..."
  sleep 120
done

echo "Completed check and all CSR's have been approved"
exit 0
