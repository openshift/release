#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc config view
oc projects

# Create infra-nodes for ingress-perf testing
if [ ${INFRA} == "true" ]; then
  if [[ $(oc get nodes -l node-role.kubernetes.io/infra= --no-headers | wc -l) != 2 ]]; then
    for node in `oc get nodes -l node-role.kubernetes.io/worker= --no-headers | head -2 | awk '{print $1}'`; do
      oc label node $node node-role.kubernetes.io/infra=""
      oc label node $node node-role.kubernetes.io/worker-;
    done
  fi
fi

if [ ${TELCO} == "true" ]; then
  # Label the nodes with percentage-based distribution
  # LABEL should contain 2 comma-separated labels: "label1,label2"
  # Distribution: 25% nodes get label1, 10% get label2, remaining 65% unlabeled
  if [ -n "${LABEL}" ]; then
    # Get all worker nodes
    readarray -t WORKER_NODES < <(oc get node -oname -l node-role.kubernetes.io/worker | grep -oP "^node/\K.*")
    TOTAL_NODES=${#WORKER_NODES[@]}
    
    if [ ${TOTAL_NODES} -eq 0 ]; then
      echo "ERROR: No worker nodes found!"
      exit 1
    fi
    
    # Parse labels into array
    IFS=',' read -ra LABELS <<< "${LABEL}"
    NUM_LABELS=${#LABELS[@]}
    
    echo "Total worker nodes: ${TOTAL_NODES}"
    echo "Labels to distribute: ${NUM_LABELS}"
    
    if [ ${NUM_LABELS} -ge 2 ]; then
      # Percentage-based distribution: 25%, 10%
      # Calculate node counts (using ceiling)
      LABEL1_COUNT=$(( (TOTAL_NODES * 25 + 99) / 100 ))  # 25% (ceiling)
      LABEL2_COUNT=$(( (TOTAL_NODES * 10 + 99) / 100 ))  # 10% (ceiling)
      UNLABELED_COUNT=$(( TOTAL_NODES - LABEL1_COUNT - LABEL2_COUNT ))  # 65% (remainder)
      
      # Ensure at least 1 node per label if we have enough nodes
      if [ ${TOTAL_NODES} -ge 2 ]; then
        [ ${LABEL1_COUNT} -lt 1 ] && LABEL1_COUNT=1
        [ ${LABEL2_COUNT} -lt 1 ] && LABEL2_COUNT=1
      fi
      
      # Adjust if counts exceed total (cap label2 if needed)
      if [ $((LABEL1_COUNT + LABEL2_COUNT)) -gt ${TOTAL_NODES} ]; then
        LABEL2_COUNT=$(( TOTAL_NODES - LABEL1_COUNT ))
        UNLABELED_COUNT=0
      fi
      
      echo "Distribution: Label1=${LABEL1_COUNT} nodes (25%), Label2=${LABEL2_COUNT} nodes (10%), Unlabeled=${UNLABELED_COUNT} nodes (65%)"
      
      # Calculate start indices
      LABEL1_START=0
      LABEL2_START=${LABEL1_COUNT}
      
      # Apply Label 1 (25% of nodes)
      LABEL1=$(echo "${LABELS[0]}" | sed 's/^ *//;s/ *$//')
      if [ -n "${LABEL1}" ] && [ ${LABEL1_COUNT} -gt 0 ]; then
        echo "=== Applying Label 1: ${LABEL1} to ${LABEL1_COUNT} nodes (25%) ==="
        for ((i=LABEL1_START; i<LABEL1_START+LABEL1_COUNT && i<TOTAL_NODES; i++)); do
          node="${WORKER_NODES[$i]}"
          echo "Applying label: ${LABEL1} to node: ${node}"
          oc label node "${node}" "${LABEL1}=" --overwrite
        done
      fi
      
      # Apply Label 2 (10% of nodes)
      LABEL2=$(echo "${LABELS[1]}" | sed 's/^ *//;s/ *$//')
      if [ -n "${LABEL2}" ] && [ ${LABEL2_COUNT} -gt 0 ]; then
        echo "=== Applying Label 2: ${LABEL2} to ${LABEL2_COUNT} nodes (10%) ==="
        for ((i=LABEL2_START; i<LABEL2_START+LABEL2_COUNT && i<TOTAL_NODES; i++)); do
          node="${WORKER_NODES[$i]}"
          echo "Applying label: ${LABEL2} to node: ${node}"
          oc label node "${node}" "${LABEL2}=" --overwrite
        done
      fi
      
      # Remaining 65% of nodes remain unlabeled (no action needed)
      if [ ${UNLABELED_COUNT} -gt 0 ]; then
        echo "=== ${UNLABELED_COUNT} nodes (65%) will remain without special labels ==="
      fi
      
    else
      # Fallback: If less than 2 labels, apply the single label to 25% of nodes
      echo "Less than 2 labels provided. Applying label to first 25% of nodes."
      LABEL1_COUNT=$(( (TOTAL_NODES * 25 + 99) / 100 ))
      [ ${LABEL1_COUNT} -lt 1 ] && LABEL1_COUNT=1
      
      for ((i=0; i<LABEL1_COUNT && i<TOTAL_NODES; i++)); do
        node="${WORKER_NODES[$i]}"
        for label in "${LABELS[@]}"; do
          label=$(echo "${label}" | sed 's/^ *//;s/ *$//')
          if [ -n "${label}" ]; then
            echo "Applying label: ${label} to node: ${node}"
            oc label node "${node}" "${label}=" --overwrite
          fi
        done
      done
    fi
    
    echo "=== Labeling Summary ==="
    oc get nodes -l node-role.kubernetes.io/worker --show-labels
  fi
fi
