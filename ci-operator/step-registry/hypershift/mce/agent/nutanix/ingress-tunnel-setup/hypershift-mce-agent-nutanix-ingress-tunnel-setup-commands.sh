#!/bin/bash

set -euo pipefail
set +x
umask 077

# Both files are created before this ref by the context and OFCIR steps.
# shellcheck source=/dev/null
source "$SHARED_DIR/nutanix_context.sh"
# shellcheck source=/dev/null
source "$SHARED_DIR/packet-conf.sh"

state_file="$SHARED_DIR/nutanix_ingress_tunnel_state.json"
ssh_config="$SHARED_DIR/nutanix_ingress_tunnel_ssh_config"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
    awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i > 255) exit 1; exit 0 } { exit 1 }' <<<"$1"
}

prism_get() {
  curl --silent --show-error --fail --insecure --max-time 45 \
    --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    "$NUTANIX_PC_URL/api/nutanix/v3/$1"
}

verify_vip_outside_dhcp_pool() {
  local subnet_json overlapping_range
  subnet_json=$(prism_get "subnets/$SUBNET_UUID")
  if ! jq -e --arg uuid "$SUBNET_UUID" --arg name "$SUBNET_NAME" --arg subnet_ip "$SUBNET_IP" \
    '.metadata.uuid == $uuid and .spec.name == $name and
     .spec.resources.ip_config.subnet_ip == $subnet_ip' <<<"$subnet_json" >/dev/null; then
    echo "The selected Nutanix subnet no longer matches the Nutanix context." >&2
    return 1
  fi

  # Nutanix v3 stores each DHCP range as two space-separated IPv4 addresses.
  # Inspect both views when present, so a stale spec or status cannot hide a
  # pool containing the MetalLB VIP.
  if ! overlapping_range=$(jq -er --arg vip "$INGRESS_VIP" '
    def ipv4_number:
      if type != "string" or (test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") | not)
      then error("invalid IPv4 address in DHCP pool")
      else split(".") | map(tonumber) |
        if all(.[]; . <= 255)
        then reduce .[] as $octet (0; . * 256 + $octet)
        else error("invalid IPv4 address in DHCP pool") end
      end;
    def pool_bounds:
      .range as $range |
      if ($range | type) != "string" then error("DHCP pool has no range")
      else ($range | split(" ") | map(select(length > 0))) as $ends |
        if ($ends | length) != 2 then error("invalid DHCP pool range")
        else [$ends[] | ipv4_number] as $numbers |
          if $numbers[0] > $numbers[1] then error("reversed DHCP pool range")
          else {range: $range, start: $numbers[0], end: $numbers[1]} end
        end
      end;
    ($vip | ipv4_number) as $vip_number |
    [(.spec.resources.ip_config.pool_list), (.status.resources.ip_config.pool_list)] |
    map(select(. != null)) as $lists |
    if ($lists | length) == 0 or any($lists[]; type != "array")
    then error("DHCP pool list is missing or invalid")
    else [$lists[][] | pool_bounds] as $pools |
      if ($pools | length) == 0 then error("DHCP pool list is empty")
      else [$pools[] | select(.start <= $vip_number and $vip_number <= .end) | .range] |
        first // "clear"
      end
    end
  ' <<<"$subnet_json"); then
    echo "Cannot verify that ingress VIP $INGRESS_VIP is outside the Nutanix DHCP pool; refusing to create a gateway." >&2
    return 1
  fi
  if [[ "$overlapping_range" != clear ]]; then
    echo "Ingress VIP $INGRESS_VIP overlaps Nutanix DHCP pool $overlapping_range; refusing to create a gateway." >&2
    return 1
  fi
}

if [[ ! "${NUTANIX_QUOTA_SLICE:-}" =~ ^[a-zA-Z0-9-]+$ || -z "${PROW_JOB_ID:-}" ]]; then
  echo "A Nutanix quota-slice lease and PROW_JOB_ID are required."
  exit 1
fi
if [[ -e "$state_file" || -e "$ssh_config" ]]; then
  echo "Tunnel state already exists; clean up the previous gateway before retrying."
  exit 1
fi
if ! valid_ipv4 "$INGRESS_VIP" || ! [[ "$SUBNET_UUID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "The Nutanix context has an invalid ingress VIP or subnet UUID."
  exit 1
fi
verify_vip_outside_dhcp_pool
port=${NUTANIX_TUNNEL_PORT:-51820}
if [[ ! "$port" =~ ^[1-9][0-9]{3,4}$ ]] || (( port < 1024 || port > 65535 )); then
  echo "NUTANIX_TUNNEL_PORT must be an unused UDP port from 1024 to 65535."
  exit 1
fi
firewall_zone_override=${NUTANIX_TUNNEL_FIREWALL_ZONE:-}
if [[ -n "$firewall_zone_override" && ! "$firewall_zone_override" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "NUTANIX_TUNNEL_FIREWALL_ZONE must name a firewalld zone."
  exit 1
fi
prefix=${NUTANIX_TUNNEL_ADDRESS_PREFIX:-100.127.255}
if ! valid_ipv4 "$prefix.1" || [[ "$prefix" == 0.* || "$prefix" == 127.* || "$prefix" == 169.254.* ]]; then
  echo "NUTANIX_TUNNEL_ADDRESS_PREFIX must be three routable IPv4 octets."
  exit 1
fi
host_tunnel_ip="$prefix.1"
gateway_tunnel_ip="$prefix.2"
tunnel_network="$prefix.0/30"
if [[ -n "${NUTANIX_TUNNEL_ENDPOINT_IP:-}" ]]; then
  endpoint_ip=$NUTANIX_TUNNEL_ENDPOINT_IP
else
  # The OFCIR SSH address can be a public forwarding address. Use the local
  # source IP selected toward the Nutanix subnet for the gateway's UDP peer.
  endpoint_route=$(ssh "${SSHOPTS[@]}" "root@$IP" ip -4 route get "$INGRESS_VIP")
  endpoint_ip=$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$endpoint_route")
fi
if ! valid_ipv4 "$endpoint_ip" || ! valid_ipv4 "$IP" ||
   [[ "$endpoint_ip" == 0.* || "$endpoint_ip" == 127.* ||
      "$endpoint_ip" == 169.254.* || "$endpoint_ip" == "$INGRESS_VIP" ]]; then
  echo "The proxy-host SSH or WireGuard endpoint is not a valid IPv4 address."
  exit 1
fi
lease=$NUTANIX_QUOTA_SLICE
run_hash=$(printf '%s' "$PROW_JOB_ID" | sha256sum | cut -c1-8)
lease_hash=$(printf '%s' "$lease" | sha256sum | cut -c1-8)
interface="wgnx${lease_hash}"
gateway_name="hcp-nxwg-${lease_hash}-${run_hash}"
image_name="${gateway_name}-rhcos"
connection_uuid=$(cat /proc/sys/kernel/random/uuid)
key_file="$CLUSTER_PROFILE_DIR/packet-ssh-key"
if [[ ! -r "$key_file" ]]; then
  echo "The packet SSH key is needed to inspect the gateway over the tunnel."
  exit 1
fi
ssh_public_key=$(ssh-keygen -y -f "$key_file")

if [[ -n "${NUTANIX_TUNNEL_IMAGE_URI:-}" ]]; then
  image_uri=$NUTANIX_TUNNEL_IMAGE_URI
else
  image_uri=$(openshift-install coreos print-stream-json |
    jq -er '.architectures.x86_64.artifacts.nutanix.formats.qcow2.disk.location')
fi
if [[ ! "$image_uri" =~ ^https://[^[:space:]]+\.qcow2$ ]]; then
  echo "A HTTPS Nutanix RHCOS qcow2 artifact is required."
  exit 1
fi

# The state is written before either Prism creation request. Cleanup can recover
# a UUID by exact run-owned name if an API response is lost after creation.
jq -n --arg lease "$lease" --arg vip "$INGRESS_VIP" --arg subnet "$SUBNET_UUID" \
  --arg name "$gateway_name" --arg image "$image_name" --arg iface "$interface" \
  --arg port "$port" --arg host "$IP" --arg endpoint "$endpoint_ip" \
  --arg hostTunnel "$host_tunnel_ip" --arg gatewayTunnel "$gateway_tunnel_ip" \
  '{lease:$lease,vip:$vip,subnetUUID:$subnet,gatewayName:$name,gatewayUUID:"",
    gatewayTaskUUID:"",gatewayIP:"",imageName:$image,imageUUID:"",
    imageTaskUUID:"",interface:$iface,port:$port,
    hostIP:$host,endpointIP:$endpoint,hostTunnelIP:$hostTunnel,
    gatewayTunnelIP:$gatewayTunnel,routeCIDR:($vip + "/32"),firewallZone:"",
    stage:"initial"}' > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

update_state() {
  local key=$1 value=$2
  jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
}

prism_post() {
  curl --silent --show-error --fail --insecure --max-time 90 \
    --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X POST \
    "$NUTANIX_PC_URL/api/nutanix/v3/$1" --data-binary "@$2"
}

wait_for_task() {
  local task=$1 description=$2 status response
  [[ "$task" =~ ^[0-9a-fA-F-]{36}$ ]] || return 1
  for ((attempt = 1; attempt <= 60; attempt++)); do
    response=$(prism_get "tasks/$task" 2>/dev/null || true)
    status=$(jq -r '.status // empty' <<< "$response")
    case "$status" in
      SUCCEEDED) return 0 ;;
      FAILED|ABORTED) echo "$description failed in Prism (task $task)."; return 1 ;;
    esac
    sleep 15
  done
  echo "Timed out waiting for $description (task $task)."
  return 1
}

# Generate both keys on the leased proxy host. Only the gateway private key is
# returned to this step so it can be passed in the VM's ignition; it is never logged.
key_material=$(ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
  "$lease" "$INGRESS_VIP" "$interface" "$port" "$tunnel_network" <<'REMOTE'
set -euo pipefail
umask 077
lease=$1 vip=$2 iface=$3 port=$4 tunnel_network=$5
state_dir=/etc/hypershift-nutanix-ingress-tunnel
marker="$state_dir/$iface.state"
key="/etc/wireguard/$iface.key"
if [[ -e "$marker" || -e "$key" || -e "/etc/wireguard/$iface.conf" ||
      -e "/etc/systemd/system/hypershift-nutanix-ingress-tunnel-$iface.service" ]]; then
  echo "A run-owned WireGuard resource already exists on the proxy host." >&2
  exit 1
fi
if ip -4 route show exact "$tunnel_network" | grep -q .; then
  echo "The proposed tunnel /30 already has a route on the proxy host." >&2
  exit 1
fi
if ip link show "$iface" >/dev/null 2>&1; then
  echo "The proposed WireGuard interface already exists on the proxy host." >&2
  exit 1
fi
if ip -4 route show exact "$vip/32" | grep -q .; then
  echo "An exact route for the ingress VIP already exists on the proxy host." >&2
  exit 1
fi
listeners=$(ss -H -lun)
if awk -v port=":$port" '$4 ~ port "$" {found=1} END {exit !found}' <<< "$listeners"; then
  echo "The WireGuard UDP port is already in use on the proxy host." >&2
  exit 1
fi
dnf install -y wireguard-tools >/dev/null
modprobe wireguard
firewall-cmd --state >/dev/null
install -d -m 700 "$state_dir" /etc/wireguard
printf '%s %s %s %s -\n' "$lease" "$vip" "$iface" "$port" > "$marker"
chmod 600 "$marker"
wg genkey > "$key"
chmod 600 "$key"
gateway_private=$(wg genkey)
host_public=$(wg pubkey < "$key")
gateway_public=$(printf '%s\n' "$gateway_private" | wg pubkey)
printf '%s\n%s\n%s\n' "$host_public" "$gateway_private" "$gateway_public"
REMOTE
)
mapfile -t keys <<< "$key_material"
if (( ${#keys[@]} != 3 )) || [[ ! "${keys[0]}" =~ ^[A-Za-z0-9+/]{43}=$ ||
      ! "${keys[1]}" =~ ^[A-Za-z0-9+/]{43}=$ || ! "${keys[2]}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "WireGuard key generation did not return three valid keys."
  exit 1
fi
host_public=${keys[0]}
gateway_private=${keys[1]}
gateway_public=${keys[2]}
unset keys key_material
update_state stage host-keys-created

# NetworkManager configures the guest WireGuard interface using its native
# keyfile support, so the isolated gateway needs no package download at boot.
cat > "$work_dir/gateway.nmconnection" <<EOF
[connection]
id=hypershift-nutanix-ingress-tunnel
uuid=$connection_uuid
type=wireguard
interface-name=$interface
autoconnect=true

[ipv4]
address1=$gateway_tunnel_ip/30
method=manual
never-default=true

[ipv6]
method=disabled

[wireguard]
private-key=$gateway_private
peer-routes=false

[wireguard-peer.$host_public]
endpoint=$endpoint_ip:$port
allowed-ips=$host_tunnel_ip/32;
persistent-keepalive=25
EOF
chmod 600 "$work_dir/gateway.nmconnection"
unset gateway_private

cat > "$work_dir/gateway.env" <<EOF
VIP=$INGRESS_VIP
HOST_TUNNEL_IP=$host_tunnel_ip
WG_INTERFACE=$interface
EOF
cat > "$work_dir/gateway-firewall.sh" <<'GATEWAY'
#!/bin/bash
set -euo pipefail
source /etc/hypershift-nutanix-ingress-tunnel/gateway.env
modprobe wireguard
for ((attempt = 1; attempt <= 90; attempt++)); do
  if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then break; fi
  sleep 2
done
ip link show "$WG_INTERFACE" >/dev/null
route=$(ip -4 route get "$VIP")
worker_interface=$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")
worker_ip=$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$route")
if [[ ! "$worker_interface" =~ ^[a-zA-Z0-9_.-]+$ ||
      ! "$worker_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ||
      "$worker_interface" == "$WG_INTERFACE" || "$worker_ip" == "$VIP" ]]; then
  echo "Could not identify the gateway's worker NIC and source address for the VIP." >&2
  exit 1
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if nft list table ip hcp_nutanix_ingress_tunnel >/dev/null 2>&1; then
  nft delete table ip hcp_nutanix_ingress_tunnel
fi
nft -f - <<RULES
table ip hcp_nutanix_ingress_tunnel {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iifname "lo" accept
    iifname "$WG_INTERFACE" ip saddr $HOST_TUNNEL_IP/32 tcp dport 22 accept
    ip protocol icmp accept
    udp sport 67 udp dport 68 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "$worker_interface" oifname "$WG_INTERFACE" ip saddr $VIP ip daddr $HOST_TUNNEL_IP/32 ct state established,related counter accept
    iifname "$WG_INTERFACE" oifname "$worker_interface" ip saddr $HOST_TUNNEL_IP/32 ip daddr $VIP tcp dport { 80, 443 } counter accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$WG_INTERFACE" oifname "$worker_interface" ip saddr $HOST_TUNNEL_IP/32 ip daddr $VIP tcp dport { 80, 443 } counter snat to $worker_ip
  }
}
RULES
GATEWAY
chmod 700 "$work_dir/gateway-firewall.sh"
cat > "$work_dir/gateway-firewall.service" <<'UNIT'
[Unit]
Description=Lease-owned Nutanix ingress WireGuard forwarding and NAT
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hypershift-nutanix-ingress-firewall
RemainAfterExit=yes
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
UNIT

jq -n --arg sshKey "$ssh_public_key" \
  --rawfile nm "$work_dir/gateway.nmconnection" \
  --rawfile env "$work_dir/gateway.env" \
  --rawfile firewall "$work_dir/gateway-firewall.sh" \
  --rawfile unit "$work_dir/gateway-firewall.service" \
  --arg nmPath "/etc/NetworkManager/system-connections/$interface.nmconnection" \
  '{ignition:{version:"3.0.0"},
    passwd:{users:[{name:"core",sshAuthorizedKeys:[$sshKey]}]},
    storage:{directories:[{path:"/etc/hypershift-nutanix-ingress-tunnel",mode:448}],files:[
      {path:$nmPath,mode:384,contents:{source:("data:text/plain;base64,"+($nm|@base64))}},
      {path:"/etc/hypershift-nutanix-ingress-tunnel/gateway.env",mode:384,contents:{source:("data:text/plain;base64,"+($env|@base64))}},
      {path:"/etc/sysctl.d/90-hypershift-nutanix-ingress-tunnel.conf",mode:420,contents:{source:"data:text/plain,net.ipv4.ip_forward%3D1%0A"}},
      {path:"/usr/local/sbin/hypershift-nutanix-ingress-firewall",mode:448,contents:{source:("data:text/plain;base64,"+($firewall|@base64))}}
    ]},
    systemd:{units:[
      {name:"firewalld.service",mask:true},
      {name:"hypershift-nutanix-ingress-firewall.service",enabled:true,contents:$unit}
    ]}}' > "$work_dir/gateway.ign"
base64 -w0 "$work_dir/gateway.ign" > "$work_dir/gateway.ign.b64"

# This run owns its image; cleanup removes it after deleting the VM.
printf '{"kind":"image","length":1000}' > "$work_dir/list.json"
existing=$(prism_post images/list "$work_dir/list.json" | jq -r --arg name "$image_name" \
  '[.entities[]? | select(.spec.name == $name)] | length')
if (( existing != 0 )); then
  echo "A Nutanix image already has the run-owned name $image_name; refusing to adopt it."
  exit 1
fi
jq -n --arg name "$image_name" --arg uri "$image_uri" \
  '{spec:{name:$name,resources:{image_type:"DISK_IMAGE",source_uri:$uri,architecture:"X86_64"}},
    metadata:{kind:"image"},api_version:"3.1.0"}' > "$work_dir/image.json"
update_state stage image-create-requested
image_response=$(prism_post images "$work_dir/image.json")
image_uuid=$(jq -er '.metadata.uuid' <<< "$image_response")
update_state imageUUID "$image_uuid"
image_task=$(jq -r '.status.execution_context.task_uuid // empty' <<< "$image_response")
if [[ -n "$image_task" ]]; then update_state imageTaskUUID "$image_task"; fi
update_state stage image-created
if [[ -n "$image_task" ]]; then wait_for_task "$image_task" 'RHCOS image import'; fi

printf '{"kind":"vm","length":1000}' > "$work_dir/list.json"
existing=$(prism_post vms/list "$work_dir/list.json" | jq -r --arg name "$gateway_name" \
  '[.entities[]? | select(.spec.name == $name)] | length')
if (( existing != 0 )); then
  echo "A Nutanix VM already has the run-owned name $gateway_name; refusing to adopt it."
  exit 1
fi
jq -n --arg name "$gateway_name" --arg image "$image_uuid" --arg subnet "$SUBNET_UUID" \
  --arg pe "$PE_UUID" --rawfile ignition "$work_dir/gateway.ign.b64" \
  '{spec:{name:$name,resources:{power_state:"ON",num_vcpus_per_socket:1,num_sockets:2,
      memory_size_mib:4096,disk_list:[{disk_size_mib:40000,
        device_properties:{device_type:"DISK",disk_address:{device_index:0,adapter_type:"SCSI"}},
        data_source_reference:{kind:"image",uuid:$image}}],
      nic_list:[{nic_type:"NORMAL_NIC",is_connected:true,
        ip_endpoint_list:[{ip_type:"DHCP"}],subnet_reference:{kind:"subnet",uuid:$subnet}}],
      guest_customization:{cloud_init:{user_data:($ignition|rtrimstr("\n"))},is_overridable:false}},
      cluster_reference:{kind:"cluster",uuid:$pe}},metadata:{kind:"vm"},api_version:"3.1.0"}' \
  > "$work_dir/vm.json"
update_state stage vm-create-requested
vm_response=$(prism_post vms "$work_dir/vm.json")
gateway_uuid=$(jq -er '.metadata.uuid' <<< "$vm_response")
update_state gatewayUUID "$gateway_uuid"
vm_task=$(jq -r '.status.execution_context.task_uuid // empty' <<< "$vm_response")
if [[ -n "$vm_task" ]]; then update_state gatewayTaskUUID "$vm_task"; fi
update_state stage vm-created
if [[ -n "$vm_task" ]]; then wait_for_task "$vm_task" 'gateway VM creation'; fi

gateway_ip=
for ((attempt = 1; attempt <= 40; attempt++)); do
  vm_json=$(prism_get "vms/$gateway_uuid" 2>/dev/null || true)
  gateway_ip=$(jq -r --arg subnet "$SUBNET_UUID" \
    '[(.status.resources.nic_list[]?, .spec.resources.nic_list[]?) |
      select(.subnet_reference.uuid == $subnet) |
      .ip_endpoint_list[]?.ip // empty] | first // empty' <<< "$vm_json")
  if valid_ipv4 "$gateway_ip"; then break; fi
  sleep 15
done
if ! valid_ipv4 "$gateway_ip" || [[ "$gateway_ip" == "$INGRESS_VIP" ]]; then
  echo "The gateway VM did not obtain a distinct DHCP address on the worker subnet."
  exit 1
fi
update_state gatewayIP "$gateway_ip"

# Only after the gateway exists do we enable the host's /32 route and UDP port.
host_zone=$(ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
  "$lease" "$INGRESS_VIP" "$interface" "$port" "$host_tunnel_ip" \
  "$gateway_tunnel_ip" "$gateway_public" "$gateway_ip" "$firewall_zone_override" <<'REMOTE'
set -euo pipefail
umask 077
lease=$1 vip=$2 iface=$3 port=$4 host_tunnel=$5 gateway_tunnel=$6 peer_public=$7 gateway_ip=$8 zone_override=$9
state_dir=/etc/hypershift-nutanix-ingress-tunnel
marker="$state_dir/$iface.state"
read -r marker_lease marker_vip marker_iface marker_port marker_zone < "$marker"
if [[ "$marker_lease" != "$lease" || "$marker_vip" != "$vip" ||
      "$marker_iface" != "$iface" || "$marker_port" != "$port" || "$marker_zone" != '-' ]]; then
  echo "The proxy-host gateway marker does not match this run." >&2
  exit 1
fi
if ip -4 route show exact "$vip/32" | grep -q .; then
  echo "An exact route for the ingress VIP already exists on the proxy host." >&2
  exit 1
fi
worker_route=$(ip -4 route get "$gateway_ip")
worker_interface=$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$worker_route")
if [[ -n "$zone_override" ]]; then
  zone=$zone_override
else
  zone=$(firewall-cmd --get-zone-of-interface="$worker_interface" 2>/dev/null || true)
  if [[ -z "$zone" || "$zone" == 'no zone' ]]; then zone=$(firewall-cmd --get-default-zone); fi
fi
if [[ ! "$zone" =~ ^[a-zA-Z0-9_-]+$ ]]; then exit 1; fi
firewall-cmd --zone="$zone" --list-all >/dev/null
if firewall-cmd --zone="$zone" --query-port="$port/udp" >/dev/null 2>&1 ||
   firewall-cmd --permanent --zone="$zone" --query-port="$port/udp" >/dev/null 2>&1; then
  echo "The WireGuard UDP port is already permitted in the proxy-host firewall zone." >&2
  exit 1
fi
listeners=$(ss -H -lun)
if awk -v port=":$port" '$4 ~ port "$" {found=1} END {exit !found}' <<< "$listeners"; then
  echo "The WireGuard UDP port is already in use on the proxy host." >&2
  exit 1
fi
config="/etc/wireguard/$iface.conf"
unit="hypershift-nutanix-ingress-tunnel-$iface.service"
key=$(cat "/etc/wireguard/$iface.key")
cat > "$config" <<CONFIG
[Interface]
PrivateKey = $key
Address = $host_tunnel/30
ListenPort = $port
Table = off
PostUp = ip route add $vip/32 dev %i src $host_tunnel
PostDown = ip route del $vip/32 dev %i || true

[Peer]
PublicKey = $peer_public
AllowedIPs = $gateway_tunnel/32, $vip/32
CONFIG
chmod 600 "$config"
cat > "/etc/systemd/system/$unit" <<UNIT
[Unit]
Description=Lease-owned Nutanix ingress VIP WireGuard tunnel
After=network-online.target firewalld.service
Wants=network-online.target firewalld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/firewall-cmd --zone=$zone --add-port=$port/udp
ExecStart=$(command -v wg-quick) up $iface
ExecStop=-$(command -v wg-quick) down $iface
ExecStopPost=-/usr/bin/firewall-cmd --zone=$zone --remove-port=$port/udp
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
UNIT
printf '%s %s %s %s %s\n' "$lease" "$vip" "$iface" "$port" "$zone" > "$marker"
systemctl daemon-reload
systemctl enable --now "$unit" >&2
systemctl is-active --quiet "$unit"
ip -4 route show exact "$vip/32" | grep -Fq "dev $iface"
printf '%s\n' "$zone"
REMOTE
)
if [[ ! "$host_zone" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "The proxy host did not report its WireGuard firewall zone."
  exit 1
fi
update_state firewallZone "$host_zone"
update_state stage host-route-active

cat > "$ssh_config" <<EOF
Host nutanix-ingress-proxy
  HostName $IP
  User root
  Port $PORT
  IdentityFile $key_file
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
Host nutanix-ingress-gateway
  HostName $gateway_tunnel_ip
  User core
  IdentityFile $key_file
  ProxyJump nutanix-ingress-proxy
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 10
EOF
chmod 600 "$ssh_config"

for ((attempt = 1; attempt <= 36; attempt++)); do
  handshake=$(ssh "${SSHOPTS[@]}" "root@$IP" wg show "$interface" latest-handshakes |
    awk '{print $2; exit}')
  if [[ "$handshake" =~ ^[0-9]+$ ]] && (( handshake > 0 && $(date +%s) - handshake < 120 )); then
    break
  fi
  sleep 10
done
if [[ ! "$handshake" =~ ^[0-9]+$ ]] || (( handshake == 0 || $(date +%s) - handshake >= 120 )); then
  echo "The Nutanix gateway did not complete a WireGuard handshake with the proxy host."
  exit 1
fi
ssh -F "$ssh_config" nutanix-ingress-gateway \
  'sudo systemctl is-active --quiet hypershift-nutanix-ingress-firewall.service'
update_state stage ready
printf 'Gateway %s (%s, %s) and the proxy-host VIP /32 route are ready for lease %s.\n' \
  "$gateway_name" "$gateway_uuid" "$gateway_ip" "$lease"
