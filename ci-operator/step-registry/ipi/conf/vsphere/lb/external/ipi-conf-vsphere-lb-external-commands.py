#!/usr/bin/env python
import base64
import gzip
import os
import re
import subprocess
import sys
import json
import ipaddress
import urllib.request
from urllib.parse import urlparse

from jinja2 import Environment, select_autoescape

try:
    from pylint.lint import Run

    file_path = os.path.realpath(__file__)
    Run([file_path], exit=False)
except ImportError:
    print("linter not available, run outside of CI")

# This step uses:
# https://github.com/openshift-splat-team/vsphere-ci-images
# https://github.com/openshift/release/pull/57722
# https://quay.io/repository/ocp-splat/vsphere-ci-python


# vSphere steps create shell scripts with exports
# to copy variables from one step to another
# this function strips "export " from the line
# then splits on the = then creates the corresponding
# environmental variable
def convert_shell_file_to_envvar(filename):
    with open(filename) as ef:
        for line in ef:
            # There are tabs in the govc.sh file
            keyvalue = line.replace('\t', '').replace('export ', '').split("=")
            os.environ[keyvalue[0]] = keyvalue[1].replace('\n', '').replace(' ','').replace('"','')


def download_import_rhcos_ova():
    branch = "release-4.14"
    uri = f"https://raw.githubusercontent.com/openshift/installer/refs/heads/{branch}/data/data/coreos/rhcos.json"

    govc_ls_vm = subprocess.run(["govc", "ls", "-t", "VirtualMachine", "*"],
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                text=True,
                                check=True)

    download_ova = False
    if govc_ls_vm.returncode == 0:
        if len(govc_ls_vm.stdout) != 0:
            for vmpath in govc_ls_vm.stdout.splitlines():
                if "rhcos-414" in vmpath:
                    return vmpath
        else:
            download_ova = True
    else:
        download_ova = True

    if download_ova:
        with urllib.request.urlopen(uri) as url:
            data = json.load(url)
            ovaurl = data["architectures"]["x86_64"]["artifacts"]["vmware"]["formats"]["ova"]["disk"]["location"]

        subprocess.run(["curl", "-L", "-o", "/tmp/rhcos.ova", ovaurl],
                       stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE,
                       text=True,
                       check=True)

        vm_template = os.path.basename(urlparse(ovaurl).path)

        vsphere_portgroup = os.environ.get("vsphere_portgroup")

        ova_import_json_string = f'''
{
        "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": {vm_template},
   "NetworkMapping":[{"Name":"VM Network","Network":"{vsphere_portgroup}"}]
}
'''

        with open("/tmp/rhcos.json", "w") as rf:
            rf.write(ova_import_json_string)

        subprocess.run(["govc", "import.ova", "-options=/tmp/rhcos.json"])


        return vm_template


cluster_profile_name = os.environ.get("CLUSTER_PROFILE_NAME")
leased_resource = os.environ.get("LEASED_RESOURCE")
shared_dir = os.environ.get("SHARED_DIR")
namespace = os.environ.get("NAMESPACE")
unique_name = os.environ.get("UNIQUE_HASH")
cluster_name = f"{namespace}-{unique_name}"
endpoints = {"api-server": 6443, "machine-config-server": 22623, "router-http": 80, "router-https": 443}

if cluster_profile_name is None:
    print("CLUSTER_PROFILE_NAME is undefined")
    sys.exit(1)

if leased_resource is None:
    print("failed to acquire lease")
    sys.exit(1)

convert_shell_file_to_envvar(shared_dir + "/vsphere_context.sh")
convert_shell_file_to_envvar(shared_dir + "/govc.sh")


ipaddresses = []
cluster_profile_dir = os.environ.get("CLUSTER_PROFILE_DIR")
vsphere_datacenter = os.environ.get("vsphere_datacenter")
vsphere_datastore = os.environ.get("vsphere_datastore")
vsphere_resource_pool = os.environ.get("vsphere_resource_pool")
prh = os.environ.get("primaryrouterhostname")
vlanid = os.environ.get("vlanid")
lb_name = f"{cluster_name}-lb"

subnets_config = os.path.join(shared_dir, "subnets.json")
if cluster_profile_name != "vsphere-elastic":
    subnets_config = "/var/run/vault/vsphere-ibmcloud-config/subnets.json"

machine_cidr_filename = os.path.join(shared_dir, "machinecidr.txt")
vips_file_name = os.path.join(shared_dir, "vips.txt")

with open(os.path.join(cluster_profile_dir, "ssh-publickey")) as f:
    ssh_pub_key = f.read()

with open(subnets_config) as sf:
    subnet_obj = json.load(sf)

    if cluster_profile_name == "vsphere-elastic":
        for key, value in subnet_obj[prh].items():
            machineNetworkCidr = value["machineNetworkCidr"]
            print(f"machine network cidr {machineNetworkCidr}")

            ipaddresses.append(ipaddress.IPv4Network(machineNetworkCidr)[10:])
    else:
        ipaddresses.append(ipaddress.IPv4Network(subnet_obj[prh][vlanid]["machineNetworkCidr"])[10:])

vips_file_name = f"{shared_dir}/vips.txt"

gateway = subnet_obj[prh][vlanid]["gateway"]
mask = subnet_obj[prh][vlanid]["mask"]
dns_server = subnet_obj[prh][vlanid]["dns_server"]
external_lb_ip_address = subnet_obj[prh][vlanid]["ipAddresses"][2]

with open(vips_file_name, "w") as vip_file:
    print(f"vip addresses {external_lb_ip_address}, {external_lb_ip_address}")
    vip_file.write(f"{external_lb_ip_address}\n{external_lb_ip_address}")

env = Environment(autoescape=select_autoescape())

haproxy_template = '''
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
  
{%- for epname, port in endpoints.items() %}
{% set health_check = "check check-ssl" %}
{% if epname is "router-http" %}
  {% set health_check = "check" %}
{% endif %}
backend {{ epname }}
  mode tcp
  balance roundrobin
  option tcp-check
  default-server verify none inter 10s downinter 5s rise 2 fall 3 slowstart 60s maxconn 250 maxqueue 256 weight 100
  
  {%- for ip in ipaddresses %}
  server {{ epname }}-{{ ip | replace(".", "-") }} {{ ip }}:{{ port }} {{ health_check }}
  {%- endfor %}
{%- endfor %}  
'''

haproxy_config = env.from_string(haproxy_template).render(endpoints=endpoints, ipaddresses=ipaddresses)

print(haproxy_config)
haproxy_config_path = "/tmp/haproxy.cfg"

with open(haproxy_config_path) as hf:
    hf.write(haproxy_config)

butane_config = f'''
variant: openshift
version: 4.14.0
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: config-openshift
storage:
  files:
    - path: "/etc/haproxy/haproxy.conf"
      contents:
        local: {haproxy_config_path} 
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
        - {ssh_pub_key}
'''

print(butane_config)

butane_config_path = "/tmp/butane.cfg"
with open(butane_config_path, "w") as bf:
    bf.write(butane_config)

vm_template = download_import_rhcos_ova()

butane = subprocess.run(["butane", "-r", "-d", "/tmp", butane_config_path],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True,
               check=True)

encoded_ign = base64.b64encode(gzip.compress(butane.stdout.encode()))

ip_config = f"ip={external_lb_ip_address}::{gateway}:{mask}:lb::none nameserver={dns_server}"

govc_ls_networks = subprocess.run(["govc", "ls", f"/{vsphere_datacenter}/network"],
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE,
                                  text=True,
                                  check=True)

r = re.compile(f".*{vlanid}$")

networks = list(filter(r.match, govc_ls_networks.stdout.splitlines()))

if len(networks) != 1:
    print(f"Network list has more than one item {networks}")
    sys.exit(1)

os.environ["GOVC_NETWORK"] = networks[0].split('/')[-1]

vsphere_portgroup_path = networks[0]

govc_clone = subprocess.run(["govc", "vm.clone", "-on=false", f"-dc=/{vsphere_datacenter}",
                             f"-ds=/{vsphere_datacenter}/datastore/{vsphere_datastore}",
                             f"-pool={vsphere_resource_pool}",
                             f"-vm={vm_template}", f"{lb_name}"],
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            text=True,
                            check=True)

govc_vm_change = subprocess.run(["govc", "vm.change", "-vm", lb_name, "-e", "guestinfo.ignition.config.data.encoding=gzip+base64"],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True,
               check=True)

if govc_vm_change.returncode != 0:
    print("govc vm change failed")
    sys.exit(1)


subprocess.run(["govc", "vm.change", "-vm", lb_name, "-e", f"guestinfo.afterburn.initrd.network-kargs={ip_config}"],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True,
               check=True)
subprocess.run(["govc", "vm.change", "-vm", lb_name, "-e", f"guestinfo.ignition.config.data={encoded_ign}"],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True,
               check=True)
subprocess.run(["govc", "vm.power", "-on", lb_name],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True,
               check=True)

with open(f"{shared_dir}/external_lb", "w") as touch:
    touch.write("\n")
