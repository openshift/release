#!/usr/bin/env bash

export KUBECONFIG

echo "Checking if any CSR's need approval"
echo "Polling for Pending CSRs 5 times at 120-second intervals"

# polling for 10 minutes, since there can be more CSR's after initial approval
for (( i = 0; i < 5; i++ )); do
  echo "CSR polling attempt $((i + 1))/5: checking for Pending CSRs"
  pending_csrs=$(oc get csr | grep Pending | awk '{print $1}')
  if [ -n "$pending_csrs" ]; then
    echo "Pending CSRs found:"
    printf '%s\n' "$pending_csrs"
    for csr in $pending_csrs; do
      echo "Approving CSR: $csr"
      oc adm certificate approve "$csr"
      approval_exit_code=$?
      echo "Approval command for CSR $csr exited with code: $approval_exit_code"
    done
    echo "Pending CSRs approved. Checking for more..."
  else
    echo "No Pending CSRs found"
  fi
  echo "Waiting 120 seconds before the next CSR polling attempt"
  sleep 120
done

echo "Completed check and all CSR's have been approved"
exit 0
