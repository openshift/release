#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

node_role=${APPLY_NODE_ROLE:=worker}
log_path=${LOG_PATH:="/var/crash"}
output_path="${ARTIFACT_DIR}/kdump"

# Gather the kdump logs from the specified node, if they exist
function gather_kdump_logs_from_node {
  echo "Gathering kdump logs for ""$1"""

  # Start the debug pod and force it to stay up until removed
  oc debug --to-namespace="default" node/"$1" -- /bin/bash -c 'sleep 300'  > /dev/null 2>&1 &

  # Check every few seconds to let the pod come up
  TIMEOUT=10
  SECONDS=0
  debug_pod=""
  until [[ -n "${debug_pod}" ]]; do
    if ((SECONDS > $TIMEOUT)); then
      break
    fi

    # Get the debug pods name
    debug_pod=$(oc get pods --namespace="default" 2>/dev/null | grep "$1-debug" | cut -d' ' -f1 || true)
    sleep 2
  done

  if [ -z "$debug_pod" ]
  then
    echo "Debug pod for node ""$1"" never activated"
  else
    echo "Pod name is: ${debug_pod}"

    # Wait for the debug pod to be ready
    oc wait -n "default" --for=condition=Ready pod/"$debug_pod" --timeout=60s

    # Copy kdump logs out of node and supress stdout
    echo "Copying kdump logs on node ""$1"""
    oc cp --loglevel 1 -n "default" "${debug_pod}:/host${log_path}" "${output_path}/${1}_kdump_logs/"  > /dev/null 2>&1

    # Cleanup the debug pod
    oc delete pod "$debug_pod" -n "default"

    # Remove directory if empty so we don't count it later
    rmdir "${output_path}/${1}_kdump_logs" > /dev/null 2>&1
  fi
}

# Gather all the kdump logs from the identified nodes in parallel
function gather_kdump_logs {
  for NODE in ${NODES}; do
    gather_kdump_logs_from_node "${NODE}" &
  done
}

# Look for and package any kdump logs found into a convenient tar file, then do cleanup
function package_kdump_logs {
  echo "INFO: Packaging the kdump logs"

  kdump_folders=""

  # Check if we got kdump output from any of the nodes
  if find ${output_path}/*/ -type d > /dev/null 2>&1; then
    echo "INFO: Crash logs detected"
    kdump_folders="$(find ${output_path}/*/ -type d)"
  fi
  
  # Only count the root directories
  num_kdump_folders="$(echo -n "${kdump_folders}" | grep -c "\_kdump\_logs\/$" || true)"

  echo "INFO: Found kdump folder(s) from ${num_kdump_folders} node(s)"

  if [ $num_kdump_folders -ne 0 ]; then
    # Package the whole folder together
    tar -czC "${output_path}" -f "${output_path}.tar.gz" .

    echo "INFO: Finished packaging the kdump logs"
  fi

  # Cleanup
  rm -rf "${output_path}"
}

node_label="node-role.kubernetes.io/${node_role}"
NODES="${*:-$(oc get nodes -l ${node_label} -o jsonpath='{.items[?(@.status.nodeInfo.operatingSystem=="linux")].metadata.name}')}"

echo $NODES

mkdir -p $output_path

gather_kdump_logs

echo "INFO: Waiting for node kdump log collection to complete ..."
wait
echo "INFO: Node log collection completed"

package_kdump_logs

sync