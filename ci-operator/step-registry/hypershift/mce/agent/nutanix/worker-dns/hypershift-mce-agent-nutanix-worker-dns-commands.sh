#!/bin/bash

set -euo pipefail
set +x

source "$SHARED_DIR/nutanix_context.sh"
CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
BASE_DOMAIN=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get dns cluster -o jsonpath='{.spec.baseDomain}')
VM_NAME="${CLUSTER_NAME}-worker-dns"
IMAGE_NAME="${VM_NAME}-rhcos"
STATE_DIR=$SHARED_DIR

if [[ "$SUBNET_NAME" != "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "Refusing to change DHCP on subnet $SUBNET_NAME: it is not the leased subnet ${NUTANIX_QUOTA_SLICE:-<unset>}."
  exit 1
fi
if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ || ! "$BASE_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "The HostedCluster name or base domain is invalid for dnsmasq."
  exit 1
fi
if [[ -e "$STATE_DIR/nutanix_dns_vm_name" || -e "$STATE_DIR/nutanix_dns_image_name" || -e "$STATE_DIR/nutanix_dns_dhcp_state.json" ]]; then
  echo "Worker DNS setup already has run-owned state; clean it up before retrying."
  exit 1
fi

function valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
    awk -F. 'NF == 4 { for (octet = 1; octet <= 4; octet++) if ($octet > 255) exit 1; exit 0 } { exit 1 }' <<<"$1"
}

function prism() {
  local method=$1
  local path=$2
  if [[ "$method" == GET ]]; then
    curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      "$NUTANIX_PC_URL/api/nutanix/v3/$path"
  else
    curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      -H 'Content-Type: application/json' -X "$method" \
      "$NUTANIX_PC_URL/api/nutanix/v3/$path" --data-binary @-
  fi
}

function wait_for_task() {
  local task_uuid=$1
  local purpose=$2
  local task_json task_state
  [[ -n "$task_uuid" ]] || return 0
  for attempt in $(seq 1 120); do
    if task_json=$(prism GET "tasks/$task_uuid" 2>/dev/null); then
      task_state=$(jq -r '.status // empty' <<<"$task_json")
      case "$task_state" in
        SUCCEEDED) return 0 ;;
        FAILED|ABORTED)
          echo "$purpose failed: $(jq -r '.error_detail // .progress_message // .status' <<<"$task_json")"
          return 1
          ;;
      esac
    fi
    sleep 10
  done
  echo "Timed out waiting for $purpose task $task_uuid."
  return 1
}

function unique_uuid() {
  local kind=$1
  local name=$2
  printf '{"kind":"%s","length":500}\n' "${kind%s}" | prism POST "$kind/list" |
    jq -r --arg name "$name" \
      '[.entities[]? | select(.spec.name == $name) | .metadata.uuid] | unique | if length == 1 then .[0] elif length == 0 then empty else error("Resource name is ambiguous") end'
}

function wait_for_named_uuid() {
  local kind=$1
  local name=$2
  local uuid
  for attempt in $(seq 1 60); do
    uuid=$(unique_uuid "$kind" "$name")
    if [[ -n "$uuid" ]]; then
      printf '%s\n' "$uuid"
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for run-owned Nutanix $kind resource $name." >&2
  return 1
}

management_ip=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get nodes -l node-role.kubernetes.io/worker= \
  -o json | jq -r '[.items[].status.addresses[]? | select(.type == "InternalIP") | .address | select(test("^[0-9.]+$"))] | first // empty')
if ! valid_ipv4 "$management_ip" || ! valid_ipv4 "$INGRESS_VIP"; then
  echo "A management worker IPv4 address and the leased ingress VIP are required."
  exit 1
fi

subnet_json=$(prism GET "subnets/$SUBNET_UUID")
if [[ $(jq -r '.metadata.uuid // empty' <<<"$subnet_json") != "$SUBNET_UUID" ||
      $(jq -r '.spec.name // empty' <<<"$subnet_json") != "$SUBNET_NAME" ]]; then
  echo "The leased subnet no longer matches the Nutanix context."
  exit 1
fi
original_options=$(jq -c '.spec.resources.ip_config.dhcp_options // null' <<<"$subnet_json")
original_servers=$(jq -c '.spec.resources.ip_config.dhcp_options.domain_name_server_list // []' <<<"$subnet_json")
if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$original_servers" >/dev/null; then
  echo "The leased subnet has an invalid DHCP DNS server list."
  exit 1
fi
upstream=${NUTANIX_DNS_UPSTREAM:-$(jq -r '[.[] | select(test("^[0-9.]+$"))] | first // empty' <<<"$original_servers")}
if ! valid_ipv4 "$upstream" || [[ "$upstream" == 127.* || "$upstream" == 0.* ]]; then
  echo "Set NUTANIX_DNS_UPSTREAM to a reachable IPv4 resolver, or configure one in the leased subnet's DHCP options."
  exit 1
fi

if [[ -n "$(unique_uuid vms "$VM_NAME")" ]]; then
  echo "Nutanix VM $VM_NAME already exists; refusing to adopt it."
  exit 1
fi

if [[ -n "${NUTANIX_DNS_IMAGE_UUID:-}" ]]; then
  image_uuid=$NUTANIX_DNS_IMAGE_UUID
  if [[ ! "$image_uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "NUTANIX_DNS_IMAGE_UUID is not a UUID."
    exit 1
  fi
  image_json=$(prism GET "images/$image_uuid")
  if [[ $(jq -r '.metadata.uuid // empty' <<<"$image_json") != "$image_uuid" ||
        $(jq -r '.spec.resources.image_type // empty' <<<"$image_json") != DISK_IMAGE ]]; then
    echo "The configured Nutanix DNS image is not a verified disk image."
    exit 1
  fi
else
  if [[ -n "$(unique_uuid images "$IMAGE_NAME")" ]]; then
    echo "Nutanix image $IMAGE_NAME already exists; refusing to adopt it."
    exit 1
  fi
  printf '%s\n' "$IMAGE_NAME" > "$STATE_DIR/nutanix_dns_image_name"
  image_response=$(jq -n --arg name "$IMAGE_NAME" --arg uri "$NUTANIX_DNS_RHCOS_URI" \
    '{api_version:"3.1.0",metadata:{kind:"image"},spec:{name:$name,resources:{image_type:"DISK_IMAGE",source_uri:$uri,architecture:"X86_64",source_options:{allow_insecure_connection:false}},description:"Run-owned worker DNS RHCOS image"}}' |
    prism POST images)
  image_uuid=$(jq -r '.metadata.uuid // empty' <<<"$image_response")
  [[ -z "$image_uuid" ]] || printf '%s\n' "$image_uuid" > "$STATE_DIR/nutanix_dns_image_uuid"
  wait_for_task "$(jq -r '.status.execution_context.task_uuid // empty' <<<"$image_response")" "DNS image import"
  image_uuid=$(wait_for_named_uuid images "$IMAGE_NAME")
  printf '%s\n' "$image_uuid" > "$STATE_DIR/nutanix_dns_image_uuid"
fi

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
cat > "$work_dir/dnsmasq.conf" <<EOF
port=53
no-resolv
no-hosts
local-service=net
bind-dynamic
server=$upstream
address=/api.$CLUSTER_NAME.$BASE_DOMAIN/$management_ip
address=/api-int.$CLUSTER_NAME.$BASE_DOMAIN/$management_ip
address=/.apps.$CLUSTER_NAME.$BASE_DOMAIN/$INGRESS_VIP
EOF
cat > "$work_dir/worker-facing-dns.service" <<'EOF'
[Unit]
Description=Run-scoped Nutanix worker DNS
Wants=NetworkManager-wait-online.service
After=NetworkManager-wait-online.service firewalld.service

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c 'if systemctl is-active --quiet firewalld; then firewall-cmd --permanent --add-service=dns && firewall-cmd --reload; fi'
ExecStart=/usr/sbin/dnsmasq --no-daemon --conf-file=/etc/worker-facing-dns.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
ignition=$(jq -n --rawfile config "$work_dir/dnsmasq.conf" --rawfile unit "$work_dir/worker-facing-dns.service" \
  '{ignition:{version:"3.2.0"},storage:{files:[{path:"/etc/worker-facing-dns.conf",mode:420,contents:{source:("data:text/plain;charset=utf-8;base64," + ($config | @base64))}}]},systemd:{units:[{name:"worker-facing-dns.service",enabled:true,contents:$unit}]}}' | base64 -w0)

printf '%s\n' "$VM_NAME" > "$STATE_DIR/nutanix_dns_vm_name"
vm_response=$(jq -n --arg name "$VM_NAME" --arg image "$image_uuid" --arg subnet "$SUBNET_UUID" \
  --arg cluster "$PE_UUID" --arg ignition "$ignition" \
  '{api_version:"3.1.0",metadata:{kind:"vm"},spec:{name:$name,resources:{power_state:"ON",num_vcpus_per_socket:1,num_sockets:2,memory_size_mib:4096,disk_list:[{disk_size_mib:20480,device_properties:{device_type:"DISK",disk_address:{device_index:0,adapter_type:"SCSI"}},data_source_reference:{kind:"image",uuid:$image}}],nic_list:[{nic_type:"NORMAL_NIC",is_connected:true,ip_endpoint_list:[{ip_type:"DHCP"}],subnet_reference:{kind:"subnet",uuid:$subnet}}],guest_customization:{cloud_init:{user_data:$ignition},is_overridable:false}},cluster_reference:{kind:"cluster",uuid:$cluster}}}' |
  prism POST vms)
vm_uuid=$(jq -r '.metadata.uuid // empty' <<<"$vm_response")
[[ -z "$vm_uuid" ]] || printf '%s\n' "$vm_uuid" > "$STATE_DIR/nutanix_dns_vm_uuid"
wait_for_task "$(jq -r '.status.execution_context.task_uuid // empty' <<<"$vm_response")" "DNS VM creation"
vm_uuid=$(wait_for_named_uuid vms "$VM_NAME")
printf '%s\n' "$vm_uuid" > "$STATE_DIR/nutanix_dns_vm_uuid"

dns_ip=""
for attempt in $(seq 1 90); do
  vm_json=$(prism GET "vms/$vm_uuid")
  dns_ip=$(jq -r '.spec.resources.nic_list[0].ip_endpoint_list[0].ip // .status.resources.nic_list[0].ip_endpoint_list[0].ip // empty' <<<"$vm_json")
  if valid_ipv4 "$dns_ip"; then
    break
  fi
  sleep 10
done
if ! valid_ipv4 "$dns_ip" || [[ "$dns_ip" == "$upstream" || "$dns_ip" == 127.* || "$dns_ip" == 0.* || "$dns_ip" == 169.254.* ]] ||
  jq -e --arg ip "$dns_ip" 'index($ip) != null' <<<"$original_servers" >/dev/null; then
  echo "The DNS VM did not receive a usable DHCP IPv4 address."
  exit 1
fi
printf '%s\n' "$dns_ip" > "$STATE_DIR/nutanix_dns_ip"

current_subnet=$(prism GET "subnets/$SUBNET_UUID")
if [[ $(jq -c '.spec.resources.ip_config.dhcp_options // null' <<<"$current_subnet") != "$original_options" ]]; then
  echo "The subnet's DHCP options changed during DNS VM provisioning; refusing to overwrite them."
  exit 1
fi
jq -n --argjson original "$original_options" --arg ip "$dns_ip" \
  '{originalOptions:$original,targetServers:[$ip]}' > "$STATE_DIR/nutanix_dns_dhcp_state.json.tmp"
mv "$STATE_DIR/nutanix_dns_dhcp_state.json.tmp" "$STATE_DIR/nutanix_dns_dhcp_state.json"
subnet_response=$(jq --arg ip "$dns_ip" \
  '{api_version,metadata,spec} | .spec.resources.ip_config.dhcp_options = (.spec.resources.ip_config.dhcp_options // {}) | .spec.resources.ip_config.dhcp_options.domain_name_server_list = [$ip]' <<<"$current_subnet" |
  prism PUT "subnets/$SUBNET_UUID")
wait_for_task "$(jq -r '.status.execution_context.task_uuid // empty' <<<"$subnet_response")" "DHCP DNS update"
advertised=false
for attempt in $(seq 1 24); do
  updated_subnet=$(prism GET "subnets/$SUBNET_UUID")
  if [[ $(jq -c '.spec.resources.ip_config.dhcp_options.domain_name_server_list // []' <<<"$updated_subnet") == "[\"$dns_ip\"]" ]]; then
    advertised=true
    break
  fi
  sleep 5
done
if [[ "$advertised" != true ]]; then
  echo "The leased subnet did not advertise the DNS VM through DHCP option 6."
  exit 1
fi

if [[ -s "$STATE_DIR/hostedcluster_no_proxy" ]]; then
  apps_suffix=".apps.$CLUSTER_NAME.$BASE_DOMAIN"
  no_proxy=$(cat "$STATE_DIR/hostedcluster_no_proxy")
  if [[ ",$no_proxy," != *",$apps_suffix,"* ]]; then
    no_proxy="$no_proxy,$apps_suffix"
    oc --kubeconfig="$SHARED_DIR/kubeconfig" patch hostedcluster "$CLUSTER_NAME" -n local-cluster \
      --type=merge -p "$(jq -nc --arg value "$no_proxy" '{spec:{configuration:{proxy:{noProxy:$value}}}}')"
    printf '%s\n' "$no_proxy" > "$STATE_DIR/hostedcluster_no_proxy"
  fi
fi

printf 'Worker DNS VM %s (%s) serves %s via DHCP on leased subnet %s.\n' \
  "$VM_NAME" "$vm_uuid" "$dns_ip" "$SUBNET_NAME"
