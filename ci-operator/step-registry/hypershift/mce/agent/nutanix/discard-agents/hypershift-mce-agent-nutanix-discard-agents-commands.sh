#!/bin/bash

set -euo pipefail

# MGMT-25581: reclaim cannot reach the management routes through the required proxy.
# These workers are disposable Nutanix VMs, so remove their Agent records before
# HostedCluster deletion can unbind them and start reclaim DaemonSets.
if [[ ! -s "$SHARED_DIR/nutanix_infraenv_name" ]]; then
  echo "No run-owned Nutanix InfraEnv was recorded; skipping Agent deletion."
  exit 0
fi

for file in cluster-name nutanix_agent_namespace kubeconfig; do
  if [[ ! -s "$SHARED_DIR/$file" ]]; then
    echo "The recorded Nutanix InfraEnv cannot be cleaned up without $file."
    exit 1
  fi
done
if [[ -z "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "NUTANIX_QUOTA_SLICE is required from the workflow lease."
  exit 1
fi

cluster_name=$(<"$SHARED_DIR/cluster-name")
agent_namespace=$(<"$SHARED_DIR/nutanix_agent_namespace")
infraenv_name=$(<"$SHARED_DIR/nutanix_infraenv_name")
if [[ ! "$cluster_name" =~ ^[a-z0-9-]+$ ||
      ! "$agent_namespace" =~ ^[a-z0-9-]+$ ||
      "$infraenv_name" != "$cluster_name-nutanix" ]]; then
  echo "The recorded Nutanix cluster, namespace, or InfraEnv name is invalid."
  exit 1
fi

export KUBECONFIG="$SHARED_DIR/kubeconfig"
run_label_key=ci.openshift.io/hcp-agent-nutanix-run
infraenv_label_key=infraenvs.agent-install.openshift.io
run_selector="$run_label_key=$cluster_name"
infraenv_selector="$infraenv_label_key=$infraenv_name"

infraenv_json=$(oc get infraenv "$infraenv_name" -n "$agent_namespace" --ignore-not-found -o json)
if [[ -n "$infraenv_json" ]] && ! jq -e --arg key "$run_label_key" --arg value "$cluster_name" \
  '.metadata.labels[$key] == $value' <<<"$infraenv_json" >/dev/null; then
  echo "The Nutanix InfraEnv is not labeled as owned by this run; refusing to delete it."
  exit 1
fi

# Include Agents that were registered before the workers step assigned its run label.
for selector in "$run_selector" "$infraenv_selector"; do
  if ! oc get agents -n "$agent_namespace" -l "$selector" -o json |
    jq -e --arg run_key "$run_label_key" --arg infraenv_key "$infraenv_label_key" \
      --arg cluster "$cluster_name" --arg infraenv "$infraenv_name" \
      'all(.items[]; (.metadata.labels[$run_key] // $cluster) == $cluster and
        .metadata.labels[$infraenv_key] == $infraenv)' >/dev/null; then
    echo "An Agent selected for deletion has conflicting run or InfraEnv ownership."
    exit 1
  fi
done

# Mark the InfraEnv deleting first. The Agent finalizer then skips spoke cleanup
# and deregisters the host without entering the unbind/reclaim path.
if [[ -n "$infraenv_json" ]]; then
  oc delete infraenv "$infraenv_name" -n "$agent_namespace" --ignore-not-found --wait=false
fi
for selector in "$run_selector" "$infraenv_selector"; do
  oc delete agents -n "$agent_namespace" -l "$selector" --ignore-not-found --wait=true --timeout=5m
  if [[ -n "$(oc get agents -n "$agent_namespace" -l "$selector" -o name)" ]]; then
    echo "Run-owned Nutanix Agents remain after deletion."
    exit 1
  fi
done
if [[ -n "$infraenv_json" ]]; then
  oc wait -n "$agent_namespace" --for=delete "infraenv/$infraenv_name" --timeout=5m
fi

echo "Deleted run-owned Nutanix Agent records before HostedCluster teardown."
