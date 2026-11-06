#!/bin/bash

set -euo pipefail

# OpenShift assigns an arbitrary UID, and OpenSSH requires a passwd entry for it.
if ! getent passwd "$(id -u)" >/dev/null; then
  /usr/local/bin/fix_uid.sh
fi

tracing_enabled=false
if [[ $- == *x* ]]; then tracing_enabled=true; fi

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
  if [[ -s "$SHARED_DIR/cluster-name" ]]; then
    oc get nmstateconfigs -n "$AGENT_NAMESPACE" -l "ci.openshift.io/hcp-agent-nutanix-run=$CLUSTER_NAME" \
      -o yaml > "$ARTIFACT_DIR/nutanix-nmstateconfigs.yaml" 2>&1 || true
  fi
fi

if [[ -s "$SHARED_DIR/nutanix_infraenv_name" && -s "$SHARED_DIR/nutanix_agent_namespace" ]]; then
  INFRAENV_NAME=$(cat "$SHARED_DIR/nutanix_infraenv_name")
  oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" -o json | jq '{metadata:{name:.metadata.name,namespace:.metadata.namespace,labels:.metadata.labels},spec:{cpuArchitecture:.spec.cpuArchitecture,pullSecretRef:.spec.pullSecretRef,proxy:.spec.proxy},status:{conditions:.status.conditions}}' > "$ARTIFACT_DIR/nutanix-infraenv.json" 2>&1 || true
fi

for file in nutanix_worker_names nutanix_worker_macs.json nutanix_worker_vms.tsv nutanix_agent_vm_mapping.tsv nutanix_squid_allowed_hosts nutanix_worker_dns_state.json; do
  if [[ -s "$SHARED_DIR/$file" ]]; then
    cp "$SHARED_DIR/$file" "$ARTIFACT_DIR/$file"
  fi
done

if [[ -s "$SHARED_DIR/nutanix_ingress_tunnel_identity.json" ]]; then
  jq '{schemaVersion,lease,prowJobID,subnetUUID,vip,interface,gatewayName,imageName}' \
    "$SHARED_DIR/nutanix_ingress_tunnel_identity.json" \
    > "$ARTIFACT_DIR/nutanix-ingress-tunnel-identity.json" || true
fi
if [[ -s "$SHARED_DIR/nutanix_ingress_tunnel_state.json" ]]; then
  jq '{lease,vip,subnetUUID,gatewayName,gatewayUUID,gatewayTaskUUID,gatewayIP,imageName,imageUUID,imageTaskUUID,interface,port,routeCIDR,firewallZone,stage}' \
    "$SHARED_DIR/nutanix_ingress_tunnel_state.json" \
    > "$ARTIFACT_DIR/nutanix-ingress-tunnel-state.json" || true
  if [[ -s "$SHARED_DIR/nutanix_ingress_tunnel_ssh_config" ]]; then
    ssh -F "$SHARED_DIR/nutanix_ingress_tunnel_ssh_config" nutanix-ingress-gateway \
      'sudo journalctl --no-pager -u hypershift-nutanix-ingress-firewall.service -n 200' \
      > "$ARTIFACT_DIR/nutanix-ingress-tunnel-gateway-journal.txt" 2>&1 || true
    ssh -F "$SHARED_DIR/nutanix_ingress_tunnel_ssh_config" nutanix-ingress-gateway \
      'sudo nft list table ip hcp_nutanix_ingress_tunnel' \
      > "$ARTIFACT_DIR/nutanix-ingress-tunnel-gateway-nft.txt" 2>&1 || true
  fi
fi

if [[ -s "$SHARED_DIR/nutanix_context.sh" ]]; then
  # Disable tracing while loading Prism credentials and fetching VM details.
  set +x
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
  if [[ "$tracing_enabled" == true ]]; then set -x; fi
fi

if [[ -f "$SHARED_DIR/packet-conf.sh" ]]; then
  # The host connection file runs SSH setup commands when sourced.
  set +x
  source "$SHARED_DIR/packet-conf.sh"
  if [[ "$tracing_enabled" == true ]]; then set -x; fi
  ssh "${SSHOPTS[@]}" "root@$IP" 'sudo podman logs --tail=500 external-squid 2>&1' > "$ARTIFACT_DIR/nutanix-squid.log" 2>&1 || true
  if [[ -s "$SHARED_DIR/nutanix_ingress_tunnel_state.json" ]]; then
    tunnel_interface=$(jq -r '.interface // empty' "$SHARED_DIR/nutanix_ingress_tunnel_state.json")
    tunnel_vip=$(jq -r '.vip // empty' "$SHARED_DIR/nutanix_ingress_tunnel_state.json")
    if [[ "$tunnel_interface" =~ ^wgnx[0-9a-f]{8}$ && "$tunnel_vip" =~ ^[0-9.]+$ ]]; then
      ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- "$tunnel_interface" "$tunnel_vip" <<'EOF' \
        > "$ARTIFACT_DIR/nutanix-ingress-tunnel-host.txt" 2>&1 || true
systemctl --no-pager status "hypershift-nutanix-ingress-tunnel-$1.service"
ip -4 route get "$2"
wg show "$1" latest-handshakes
wg show "$1" transfer
EOF
    fi
  fi
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
