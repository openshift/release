#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# notes: jcallen: we need vlanid and primaryrouterhostname
declare vlanid
declare primaryrouterhostname
declare vsphere_datacenter
declare vsphere_portgroup
declare dns_server
#declare vsphere_datastore
#declare vsphere_resource_pool
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

echo "$(date -u --rfc-3339=seconds) - Setting up external load balancer"

SUBNETS_CONFIG=/var/run/vault/vsphere-ibmcloud-config/subnets.json
if [[ "${CLUSTER_PROFILE_NAME:-}" == "vsphere-elastic" ]]; then
    SUBNETS_CONFIG="${SHARED_DIR}/subnets.json"
fi

if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi

# ** NOTE: The first two addresses are not for use. [0] is the network, [1] is the gateway

gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
mask=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].mask' "${SUBNETS_CONFIG}")
external_lb_ip_address=$(jq -r --argjson N 2 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")

jq -r --argjson N 2 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
jq -r --argjson N 2 --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/vips.txt
jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}" >>"${SHARED_DIR}"/machinecidr.txt

machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

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


echo "$(date -u --rfc-3339=seconds) - Checking if RHCOS OVA needs to be downloaded from ${OVA_URL}..."

if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${OVA_URL}..."
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

  if [[ "${EP_NAMES[$i]}" = "router-http" ]]; then
    health_check="check"
  else
    health_check="check check-ssl"
  fi

  for ip in {10..127}; do
    ipaddress=$(jq -r --argjson N "$ip" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")

    # to reduce the size of the network objects the ipaddress list is truncated. Let's generate it instead
    if [[ "${CLUSTER_PROFILE_NAME:-}" == "vsphere-elastic" ]]; then
        ipaddress=$(python -c "import ipaddress;print(ipaddress.IPv4Network('${machine_cidr}')[${ip}])")
    fi

    echo "   "server ${EP_NAMES[$i]}-${ip} ${ipaddress}:${EP_PORTS[$i]} ${health_check} >>$HAPROXY_PATH
    if [[ -n "${VSPHERE_EXTRA_LEASED_RESOURCE:-}" ]]; then
      for extra_leased_resource in ${VSPHERE_EXTRA_LEASED_RESOURCE}; do
          extra_router=$(awk -F. '{print $1}' <(echo "${extra_leased_resource}"))
	  extra_phydc=$(awk -F. '{print $2}' <(echo "${extra_leased_resource}"))
	  extra_vlanid=$(awk -F. '{print $3}' <(echo "${extra_leased_resource}"))
	  extra_primaryrouterhostname="${extra_router}.${extra_phydc}"
	  ipaddress=$(jq -r --argjson N "$ip" --arg PRH "$extra_primaryrouterhostname" --arg VLANID "$extra_vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")
	  echo "   "server ${EP_NAMES[$i]}${extra_vlanid}-${ip} ${ipaddress}:${EP_PORTS[$i]} ${health_check} >>$HAPROXY_PATH
      done
    fi
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

# Make sure we are only grabbing the networks that are ci-vlan-#### and not -1 -2 or -test
vsphere_portgroup_path=$(govc ls /${vsphere_datacenter}/network | grep "${vlanid}$")

govc vm.clone -on=false -dc=/${vsphere_datacenter} -ds /${vsphere_datacenter}/datastore/mdcnc-ds-shared -pool=/IBMCloud/host/vcs-mdcnc-workload-1/Resources -vm="${vm_template}" "${LB_VMNAME}"

govc vm.network.change -dc=/${vsphere_datacenter} -vm "${LB_VMNAME}" -net "${vsphere_portgroup_path}" ethernet-0
IGN=$(cat $BUTANE_CFG | /tmp/butane -r -d /tmp | gzip | base64 -w0)

IPCFG="ip=${external_lb_ip_address}::${gateway}:${mask}:lb::none nameserver=${dns_server}"

govc vm.change -vm "${LB_VMNAME}" -e "guestinfo.afterburn.initrd.network-kargs=${IPCFG}"
govc vm.change -vm "${LB_VMNAME}" -e guestinfo.ignition.config.data=$IGN
govc vm.change -vm "${LB_VMNAME}" -e guestinfo.ignition.config.data.encoding=gzip+base64
govc vm.power -on "${LB_VMNAME}"

touch $SHARED_DIR/external_lb
