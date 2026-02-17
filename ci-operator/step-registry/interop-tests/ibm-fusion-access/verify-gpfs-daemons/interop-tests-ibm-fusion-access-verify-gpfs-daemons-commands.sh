#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__GPFS_TIMEOUT="${FA__GPFS_TIMEOUT:-600}"

: 'Verifying GPFS daemon state on all nodes...'

pod=$(oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core -o name | head -1)

if [[ -z "$pod" ]]; then
  : 'ERROR: No GPFS daemon pods found'
  oc get pods -n "${FA__SCALE__NAMESPACE}" -l app.kubernetes.io/name=core --ignore-not-found
  exit 1
fi

: "Using pod: ${pod}"

elapsed=0
while [ $elapsed -lt $FA__GPFS_TIMEOUT ]; do
  gpfsState=$(oc exec -n "${FA__SCALE__NAMESPACE}" ${pod} -c gpfs -- mmgetstate -a)
  
  : 'Current GPFS state:'
  : "${gpfsState}"
  
  if echo "$gpfsState" | grep -q "mmgetstate not available yet"; then
    : 'GPFS not ready yet, waiting...'
    # sleep required: polling GPFS daemon state via mmgetstate has no oc wait equivalent
    sleep 15
    elapsed=$((elapsed + 15))
    continue
  fi
  
  totalNodes=$(echo "$gpfsState" | grep -E "^\s+[0-9]+" | wc -l) || totalNodes=0
  activeNodes=$(echo "$gpfsState" | grep -E "^\s+[0-9]+" | grep -c "active") || activeNodes=0
  
  : "GPFS nodes: ${activeNodes}/${totalNodes} active"
  
  if [[ "$totalNodes" -gt 0 ]] && [[ "$activeNodes" -eq "$totalNodes" ]]; then
    : 'All GPFS nodes are active'
    break
  fi
  
  downNodes=$(echo "$gpfsState" | grep -E "^\s+[0-9]+" | grep -v "active" || true)
  if [[ -n "$downNodes" ]]; then
    : 'Nodes not yet active:'
    : "${downNodes}"
  fi
  
  # sleep required: polling GPFS daemon state via mmgetstate has no oc wait equivalent
  sleep 15
  elapsed=$((elapsed + 15))
  : "Elapsed: ${elapsed}/${FA__GPFS_TIMEOUT}s"
done

if [[ $elapsed -ge $FA__GPFS_TIMEOUT ]]; then
  : 'ERROR: Timeout waiting for GPFS daemons to become active'
  : 'Final GPFS state:'
  if ! oc exec -n "${FA__SCALE__NAMESPACE}" ${pod} -c gpfs -- mmgetstate -a; then
    : '(mmgetstate failed)'
  fi
  : 'Daemon pod logs (last 50 lines):'
  if ! oc logs -n "${FA__SCALE__NAMESPACE}" ${pod} -c gpfs --tail=50; then
    : '(logs not available)'
  fi
  exit 1
fi

: 'GPFS daemon verification complete - all nodes active'

true
