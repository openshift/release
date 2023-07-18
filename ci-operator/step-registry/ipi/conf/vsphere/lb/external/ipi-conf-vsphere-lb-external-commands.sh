#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

echo "$(date -u --rfc-3339=seconds) - Setting up external load balancer"

third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

echo "192.168.${third_octet}.2" >> "${SHARED_DIR}"/vips.txt
echo "192.168.${third_octet}.2" >> "${SHARED_DIR}"/vips.txt
echo "192.168.${third_octet}.0/25" >> "${SHARED_DIR}"/machinecidr.txt

echo "Reserved the following IP addresses..."
cat "${SHARED_DIR}"/vips.txt

if openshift-install coreos print-stream-json 2>/tmp/err.txt >/tmp/coreos-print-stream.json; then
  # shellcheck disable=SC2155
  export OVA_URL="$(jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location' /tmp/coreos-print-stream.json)"
else
  # shellcheck disable=SC2155
  export OVA_URL="$(jq -r '.baseURI + .images["vmware"].path' /var/lib/openshift-install/rhcos.json)"
fi

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

vm_template="${OVA_URL##*/}"

# Troubleshooting UPI OVA import issue
echo "$(date -u --rfc-3339=seconds) - vm_template: ${vm_template}"

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

cat > /tmp/rhcos.json << EOF
{
   "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": "${vm_template}",
   "NetworkMapping":[{"Name":"VM Network","Network":"${LEASED_RESOURCE}"}]
}
EOF

echo "$(date -u --rfc-3339=seconds) - Checking if RHCOS OVA needs to be downloaded from ${OVA_URL}..."

if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]
then
    echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${OVA_URL}..."
    curl -L -o /tmp/rhcos.ova "${OVA_URL}"
    govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
    wait "$!"
fi

HAPROXY_PATH=/tmp/haproxy.cfg
BUTANE_CFG=/tmp/butane.cfg

cat > $HAPROXY_PATH <<-EOF
defaults
  mode tcp
  maxconn 20000
  option dontlognull
  timeout http-request 30s
  timeout connect 10s
  timeout client 86400s
  timeout queue 1m
  timeout server 86400s
  timeout tunnel 86400s
  retries 3rbos

frontend api-server
  bind *:6443
  default_backend api-server

frontend machine-config-server
  bind *:22623
  default_backend machine-config-server

frontend router-http
  bind *:80
  default_backend router-http

frontend router-https
  bind *:443
  default_backend router-https
EOF

EP_NAMES=("api-server" "machine-config-server" "router-http" "router-https")
EP_PORTS=("6443" "22623" "80" "443")

for i in "${!EP_NAMES[@]}"; do
cat >> $HAPROXY_PATH <<-EOF

backend ${EP_NAMES[$i]}
  mode tcp
  balance roundrobin
  option tcp-check  
  default-server verify none inter 10s downinter 5s rise 2 fall 3 slowstart 60s maxconn 250 maxqueue 256 weight 100
EOF

  for ip in {10..127}; do
    echo "   "server ${EP_NAMES[$i]}-${ip} 192.168.${third_octet}.${ip}:${EP_PORTS[$i]} check check-ssl >> $HAPROXY_PATH
  done
done

cat > $BUTANE_CFG <<-EOF
variant: openshift
version: 4.12.0
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: config-openshift
storage: 
  files:
    - path: "/etc/haproxy/haproxy.conf"            
      contents:
        local: ./haproxy.cfg        
      mode: 0644              
systemd:
  units:
    - name: haproxy.service
      enabled: true
      contents: |
        [Unit]
        Description=haproxy
        After=network-online.target
        Wants=network-online.target

        [Service]
        Restart=always
        RestartSec=3
        ExecStartPre=-/bin/podman kill haproxy
        ExecStartPre=-/bin/podman rm haproxy
        ExecStartPre=/bin/podman pull quay.io/openshift/origin-haproxy-router
        ExecStart=/bin/podman run --name haproxy \
        --net=host \
        --privileged \
        --entrypoint=/usr/sbin/haproxy \
        -v /etc/haproxy/haproxy.conf:/var/lib/haproxy/conf/haproxy.conf:Z \
        quay.io/openshift/origin-haproxy-router -f /var/lib/haproxy/conf/haproxy.conf
        ExecStop=/bin/podman rm -f haproxy

        [Install]
        WantedBy=multi-user.target
passwd:
  users:
    - name: core
      ssh_authorized_keys: 
        - ${ssh_pub_key}
EOF

curl -sSL "https://mirror2.openshift.com/pub/openshift-v4/clients/butane/latest/butane" --output /tmp/butane && chmod +x /tmp/butane

LB_VMNAME="${cluster_name}-lb"
export GOVC_NETWORK="${LEASED_RESOURCE}"
govc vm.clone -on=false -vm="${vm_template}" ${LB_VMNAME}
IGN=$(cat $BUTANE_CFG | /tmp/butane -r -d /tmp | gzip | base64 -w0)
IPCFG="ip=192.168.${third_octet}.2::192.168.${third_octet}.1:255.255.255.0:lb::none nameserver=8.8.8.8"
govc vm.network.change -vm ${LB_VMNAME} -net "${LEASED_RESOURCE}" ethernet-0
govc vm.change -vm ${LB_VMNAME} -e "guestinfo.afterburn.initrd.network-kargs=${IPCFG}"
govc vm.change -vm ${LB_VMNAME} -e guestinfo.ignition.config.data=$IGN
govc vm.change -vm ${LB_VMNAME} -e guestinfo.ignition.config.data.encoding=gzip+base64
govc vm.power -on ${LB_VMNAME}

touch $SHARED_DIR/external_lb

