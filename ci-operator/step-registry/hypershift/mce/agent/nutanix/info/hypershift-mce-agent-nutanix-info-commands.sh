#!/bin/bash

set -euo pipefail
set +x

mkdir -p "$ARTIFACT_DIR"
export KUBECONFIG="$SHARED_DIR/kubeconfig"

if [[ -s "$SHARED_DIR/cluster-name" ]]; then
  CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
  oc get hostedcluster "$CLUSTER_NAME" -n local-cluster -o yaml > "$ARTIFACT_DIR/nutanix-hostedcluster.yaml" 2>&1 || true
  oc get nodepool "$CLUSTER_NAME" -n local-cluster -o yaml > "$ARTIFACT_DIR/nutanix-nodepool.yaml" 2>&1 || true
fi

if [[ -s "$SHARED_DIR/nutanix_agent_namespace" ]]; then
  AGENT_NAMESPACE=$(cat "$SHARED_DIR/nutanix_agent_namespace")
  oc get agents -n "$AGENT_NAMESPACE" -o yaml > "$ARTIFACT_DIR/nutanix-agents.yaml" 2>&1 || true
  oc get events -n "$AGENT_NAMESPACE" --sort-by=.lastTimestamp > "$ARTIFACT_DIR/nutanix-agent-events.txt" 2>&1 || true
fi

if [[ -s "$SHARED_DIR/nutanix_infraenv_name" && -s "$SHARED_DIR/nutanix_agent_namespace" ]]; then
  INFRAENV_NAME=$(cat "$SHARED_DIR/nutanix_infraenv_name")
  oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" -o json | jq '{metadata:{name:.metadata.name,namespace:.metadata.namespace,labels:.metadata.labels},spec:{cpuArchitecture:.spec.cpuArchitecture,pullSecretRef:.spec.pullSecretRef,proxy:.spec.proxy},status:{conditions:.status.conditions}}' > "$ARTIFACT_DIR/nutanix-infraenv.json" 2>&1 || true
fi

for file in nutanix_worker_names nutanix_worker_vms.tsv nutanix_agent_vm_mapping.tsv nutanix_squid_allowed_hosts nutanix_worker_dns_state.json; do
  if [[ -s "$SHARED_DIR/$file" ]]; then
    cp "$SHARED_DIR/$file" "$ARTIFACT_DIR/$file"
  fi
done

if [[ -s "$SHARED_DIR/nutanix_context.sh" ]]; then
  source "$SHARED_DIR/nutanix_context.sh"
  if [[ -s "$SHARED_DIR/vm_uuids.txt" ]]; then
    : > "$ARTIFACT_DIR/nutanix-vms.jsonl"
    while IFS= read -r uuid; do
      [[ -n "$uuid" ]] || continue
      response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
        "$NUTANIX_PC_URL/api/nutanix/v3/vms/$uuid") || continue
      jq -c '{uuid:.metadata.uuid,name:.spec.name,nics:[.spec.resources.nic_list[]? | {mac_address,subnet_uuid}],power_state:.status.resources.power_state}' <<<"$response" >> "$ARTIFACT_DIR/nutanix-vms.jsonl"
    done < "$SHARED_DIR/vm_uuids.txt"
  fi
fi

if [[ -f "$SHARED_DIR/packet-conf.sh" ]]; then
  source "$SHARED_DIR/packet-conf.sh"
  ssh "${SSHOPTS[@]}" "root@$IP" 'sudo podman logs --tail=500 external-squid 2>&1' > "$ARTIFACT_DIR/nutanix-squid.log" 2>&1 || true
  if [[ -s "$SHARED_DIR/nutanix_worker_dns_state.json" ]]; then
    dns_cluster=$(jq -r '.cluster' "$SHARED_DIR/nutanix_worker_dns_state.json")
    if [[ "$dns_cluster" =~ ^[a-z0-9-]+$ ]]; then
      ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- "$dns_cluster" <<'EOF' > "$ARTIFACT_DIR/nutanix-worker-dns.log" 2>&1 || true
unit="hypershift-nutanix-worker-dns-$1.service"
systemctl --no-pager status "$unit"
journalctl --no-pager -u "$unit" -n 200
ss -lntu '( sport = :53 )'
marker="/etc/hypershift-nutanix-worker-dns/$1.state"
if [[ -s "$marker" ]]; then
  read -r marker_cluster marker_bind marker_clients zone < "$marker"
  firewall-cmd --zone="$zone" --list-rich-rules
fi
EOF
    fi
  fi
fi

if [[ -s "$SHARED_DIR/nutanix_squid_allowed_hosts" ]]; then
  cp "$SHARED_DIR/nutanix_squid_allowed_hosts" "$ARTIFACT_DIR/nutanix-squid-allowed-hosts.txt"
fi
