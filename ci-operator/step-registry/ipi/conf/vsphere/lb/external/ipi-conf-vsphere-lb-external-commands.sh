#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

function log() {
  echo "$(date -u --rfc-3339=seconds) - ${1}"
}

# getNetworkParamters sets variables associated with the network at the provided path
function getNetworkParamters() {  
  log "getting network parameters for $1"

  mask=$(cat $1 | jq -r .spec.netmask)
  gateway=$(cat $1 | jq -r .spec.gateway)
  machine_network_cidr=$(cat $1 | jq -r .spec.machineNetworkCidr)
  dns_server=${gateway}
  octet1=$(echo "${gateway}" | cut -d. -f1)
  octet2=$(echo "${gateway}" | cut -d. -f2)
  octet3=$(echo "${gateway}" | cut -d. -f3)
  octet4=$(echo "${gateway}" | cut -d. -f4)
  ip_address_count=$(cat $1 | jq -r .spec.ipAddressCount)
}

# notes: jcallen: we need vlanid and primaryrouterhostname
declare vlanid
declare primaryrouterhostname
declare vsphere_datacenter
declare vsphere_portgroup
declare dns_server
declare vsphere_datastore
declare vsphere_resource_pool
declare NETWORK_PATH
source "${SHARED_DIR}/vsphere_context.sh"

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

log "Setting up external load balancer"

# derive load balancer host network details and VIP
getNetworkParamters ${NETWORK_PATH}

lb_mask=${mask}
lb_gateway=${gateway}
lb_dns=${gateway}
vip=${octet1}.${octet2}.${octet3}.$(($octet4+1))
echo ${vip} > "${SHARED_DIR}"/vips.txt
echo ${vip} >> "${SHARED_DIR}"/vips.txt
echo ${machine_network_cidr} > "${SHARED_DIR}"/machinecidr.txt

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
log "vm_template: ${vm_template}"

log "Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

cat >/tmp/rhcos.json <<EOF
{
   "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": "${vm_template}",
   "NetworkMapping":[{"Name":"VM Network","Network":"${vsphere_portgroup}"}]
}
EOF


log "Checking if RHCOS OVA needs to be downloaded from ${OVA_URL}..."

if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]; then
  log "Creating a template for the VMs from ${OVA_URL}..."
  curl -L -o /tmp/rhcos.ova "${OVA_URL}"
  govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
  wait "$!"
fi

HAPROXY_PATH=/tmp/haproxy.cfg
BUTANE_CFG=/tmp/butane.cfg

cat >$HAPROXY_PATH <<-EOF
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

# configure endpoints for any network associated with the job
EP_NAMES=("api-server" "machine-config-server" "router-http" "router-https")
EP_PORTS=("6443" "22623" "80" "443")

for i in "${!EP_NAMES[@]}"; do
  cat >>$HAPROXY_PATH <<-EOF

backend ${EP_NAMES[$i]}
  mode tcp
  balance roundrobin
  option tcp-check
  default-server verify none inter 10s downinter 5s rise 2 fall 3 slowstart 60s maxconn 250 maxqueue 256 weight 100
EOF

  # read shared network configuration
  for _networkJSON in $(ls -d $SHARED_DIR/NETWORK*); do
    if [[ _networkJSON =~ "single" ]]; then
      continue
    fi

    getNetworkParamters ${_networkJSON}

    log "creating endpoints for haproxy for network ${_networkJSON}"
    endCount=$((${ip_address_count}-2))
    for (( ipindex=2; ipindex < $endCount; ipindex++ )) do
      ip="${octet1}.${octet2}.${octet3}.$(( ${octet4} + ${ipindex} ))"
      log "server ${EP_NAMES[$i]}-${ip} ${ip}:${EP_PORTS[$i]} check check-ssl"
      echo "   "server ${EP_NAMES[$i]}-${ip} ${ip}:${EP_PORTS[$i]} check check-ssl >>$HAPROXY_PATH
    done
  done
done

cat >$BUTANE_CFG <<-EOF
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

cat ${HAPROXY_PATH}

curl -sSL "https://mirror2.openshift.com/pub/openshift-v4/clients/butane/latest/butane" --output /tmp/butane && chmod +x /tmp/butane

LB_VMNAME="${cluster_name}-lb"
export GOVC_NETWORK="${vsphere_portgroup}"
export GOVC_RESOURCE_POOL="${vsphere_resource_pool}"
  vsphere_portgroup_path=$(govc ls /${vsphere_datacenter}/network | grep "${vlanid}")
  log "cloning load balancer VM"
  govc vm.clone -on=false -dc=/${vsphere_datacenter} -ds /${vsphere_datacenter}/datastore/${vsphere_datastore} -pool=${vsphere_resource_pool} -vm="${vm_template}" "${LB_VMNAME}"

  log "updating network to portgroup ${GOVC_NETWORK}"
  govc vm.network.change -dc=/${vsphere_datacenter} -vm "${LB_VMNAME}" -net "${vsphere_portgroup_path}" ethernet-0
IGN=$(cat $BUTANE_CFG | /tmp/butane -r -d /tmp | gzip | base64 -w0)

IPCFG="ip=${vip}::${gateway}:${mask}:lb::none nameserver=${dns_server}"

log "initializing extra config"
govc vm.change -vm "${LB_VMNAME}" -e "guestinfo.afterburn.initrd.network-kargs=${IPCFG}"
govc vm.change -vm "${LB_VMNAME}" -e guestinfo.ignition.config.data=$IGN
govc vm.change -vm "${LB_VMNAME}" -e guestinfo.ignition.config.data.encoding=gzip+base64

log "powering on load balancer VM"
govc vm.power -on "${LB_VMNAME}"

touch $SHARED_DIR/external_lb
