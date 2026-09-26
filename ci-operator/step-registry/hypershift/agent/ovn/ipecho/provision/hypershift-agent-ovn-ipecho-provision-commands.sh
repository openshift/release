#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Provisioning ipecho server on dev-scripts host"

source "${SHARED_DIR}/packet-conf.sh"

# Defaults to the baremetal bridge. Point it at an extra network's gateway
# (e.g. 192.168.221.1) when testing EgressIP on a secondary host interface, so the
# echo target is reached over that NIC instead of over br-ex.
IPECHO_HOST_IP="${IPECHO_HOST_IP:-192.168.111.1}"
IPECHO_PORT="${IPECHO_PORT:-9095}"

# When the guest nodes egress over an 802.1Q VLAN rather than over the untagged extra
# network, the echo target has to sit on that VLAN too: a tagged frame leaving the node
# is only delivered to a host netdev that carries the same tag. IPECHO_VLAN_ID creates
# that subinterface on whichever bridge holds IPECHO_HOST_IP, and IPECHO_VLAN_CIDR gives
# it an address, which then becomes the advertised echo address.
IPECHO_VLAN_ID="${IPECHO_VLAN_ID:-}"
IPECHO_VLAN_CIDR="${IPECHO_VLAN_CIDR:-}"

if [[ -n "${IPECHO_VLAN_ID}" && -z "${IPECHO_VLAN_CIDR}" ]] ||
   [[ -z "${IPECHO_VLAN_ID}" && -n "${IPECHO_VLAN_CIDR}" ]]; then
  echo "ERROR: IPECHO_VLAN_ID and IPECHO_VLAN_CIDR must be set together"
  exit 1
fi

# Everything downstream targets this. It is the VLAN address when tagged, and the
# bridge address otherwise.
IPECHO_SERVICE_IP="${IPECHO_HOST_IP}"
if [[ -n "${IPECHO_VLAN_ID}" ]]; then
  IPECHO_SERVICE_IP="${IPECHO_VLAN_CIDR%/*}"
fi

# Deploy ipecho server on the provisioning host via SSH
# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- \
  "${IPECHO_PORT}" "${IPECHO_HOST_IP}" "${IPECHO_VLAN_ID}" "${IPECHO_VLAN_CIDR}" \
  "${IPECHO_SERVICE_IP}" << 'EOF'
set -euxo pipefail

IPECHO_PORT="$1"
IPECHO_HOST_IP="$2"
IPECHO_VLAN_ID="$3"
IPECHO_VLAN_CIDR="$4"
IPECHO_SERVICE_IP="$5"

# Write the ipecho Python HTTP server
cat > /usr/local/bin/ipecho.py << 'PYEOF'
#!/usr/bin/env python3
"""Minimal HTTP server that returns the client source IP address."""
import http.server
import socketserver
import sys

class IPEchoHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # The body is the bare address with no trailing newline. The test helper
        # verifyEgressIPWithIPEcho compares the unmodified stdout of curl against the
        # expected address, so a newline here makes every comparison fail. This matches
        # the quay.io/openshifttest/ip-echo image the cloud jobs use.
        client_ip = self.client_address[0]
        body = client_ip.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" %
                         (self.client_address[0],
                          self.log_date_time_string(),
                          fmt % args))

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9095
    with socketserver.TCPServer(("0.0.0.0", port), IPEchoHandler) as httpd:
        print(f"ipecho server listening on 0.0.0.0:{port}")
        httpd.serve_forever()
PYEOF
chmod +x /usr/local/bin/ipecho.py

# Create systemd unit
cat > /etc/systemd/system/ipecho.service << SVCEOF
[Unit]
Description=ipecho HTTP server for EgressIP testing
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ipecho.py ${IPECHO_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now ipecho.service

# The server binds 0.0.0.0, but the address we advertise has to actually be on the
# host, and firewalld has to let the guests reach the port on that bridge. libvirt
# puts NAT network bridges in the "libvirt" zone, which only permits DHCP/DNS/SSH/TFTP,
# so an extra network needs the port opened explicitly.
IPECHO_BRIDGE="$(ip -o -4 addr show | awk -v pfx="${IPECHO_HOST_IP}/" '$4 ~ "^"pfx {print $2; exit}')"
if [[ -z "${IPECHO_BRIDGE}" ]]; then
    echo "ERROR: no interface on this host holds ${IPECHO_HOST_IP}"
    ip -o -4 addr show
    exit 1
fi
echo "ipecho address ${IPECHO_HOST_IP} is on ${IPECHO_BRIDGE}"

IPECHO_IFACES="${IPECHO_BRIDGE}"

if [[ -n "${IPECHO_VLAN_ID}" ]]; then
    # Tagged frames only cross the bridge untouched while VLAN filtering is off, which
    # is how libvirt creates NAT network bridges. If something has turned it on, the
    # guests' tagged traffic is dropped at the bridge and the symptom downstream is an
    # unreachable echo server rather than anything pointing back here.
    filtering="$(cat "/sys/class/net/${IPECHO_BRIDGE}/bridge/vlan_filtering" 2>/dev/null || echo 0)"
    if [[ "${filtering}" != "0" ]]; then
        echo "ERROR: ${IPECHO_BRIDGE} has vlan_filtering=${filtering}; tagged frames from the"
        echo "       guests will not reach a VLAN subinterface on this bridge."
        exit 1
    fi

    IPECHO_VLAN_IFACE="${IPECHO_BRIDGE}.${IPECHO_VLAN_ID}"
    if ! ip link show "${IPECHO_VLAN_IFACE}" >/dev/null 2>&1; then
        ip link add link "${IPECHO_BRIDGE}" name "${IPECHO_VLAN_IFACE}" \
            type vlan id "${IPECHO_VLAN_ID}"
    fi
    # Idempotent so a rerun against a warm host does not fail on EEXIST.
    ip addr replace "${IPECHO_VLAN_CIDR}" dev "${IPECHO_VLAN_IFACE}"
    ip link set "${IPECHO_VLAN_IFACE}" up
    ip -o -4 addr show dev "${IPECHO_VLAN_IFACE}"

    IPECHO_IFACES="${IPECHO_IFACES} ${IPECHO_VLAN_IFACE}"
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    # The VLAN netdev is created outside NetworkManager, so it lands in the default
    # zone rather than inheriting the bridge's. Open the port in both.
    for iface in ${IPECHO_IFACES}; do
        zone="$(firewall-cmd --get-zone-of-interface="${iface}" 2>/dev/null || true)"
        if [[ -z "${zone}" || "${zone}" == "no zone" ]]; then
            zone="$(firewall-cmd --get-default-zone)"
        fi
        firewall-cmd --zone="${zone}" --add-port="${IPECHO_PORT}/tcp" || true
        firewall-cmd --zone="${zone}" --list-ports || true
    done
else
    echo "firewalld not running; relying on the host's default filtering"
fi

# Verify the service is running on the address the guests will actually target
for i in $(seq 1 30); do
    if curl -sf "http://${IPECHO_SERVICE_IP}:${IPECHO_PORT}" >/dev/null 2>&1; then
        echo "ipecho server is ready on ${IPECHO_SERVICE_IP}:${IPECHO_PORT}"
        curl -s "http://${IPECHO_SERVICE_IP}:${IPECHO_PORT}"
        exit 0
    fi
    echo "Waiting for ipecho server... attempt ${i}/30"
    sleep 2
done

echo "ERROR: ipecho server did not become ready"
systemctl status ipecho.service || true
journalctl -u ipecho.service --no-pager -n 20 || true
exit 1
EOF

echo "ipecho server deployed successfully"

# Write outputs for downstream test steps. These carry the VLAN address when tagged,
# so consumers never need to know which topology the job is running.
echo "${IPECHO_SERVICE_IP}" > "${SHARED_DIR}/ipecho_host_ip"
echo "http://${IPECHO_SERVICE_IP}:${IPECHO_PORT}" > "${SHARED_DIR}/ipecho_url"
if [[ -n "${IPECHO_VLAN_ID}" ]]; then
  echo "${IPECHO_VLAN_ID}" > "${SHARED_DIR}/ipecho_vlan_id"
fi

echo "ipecho_host_ip: ${IPECHO_SERVICE_IP}"
echo "ipecho_url: http://${IPECHO_SERVICE_IP}:${IPECHO_PORT}"
