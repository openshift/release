#!/usr/bin/env python
import base64
import gzip
import os
import re
import subprocess
import sys
import json
import ipaddress
import traceback
import urllib.request
import logging
from subprocess import CalledProcessError
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

logging.basicConfig(format='%(asctime)s %(levelname)s [%(filename)s:%(lineno)d] %(message)s', level=logging.INFO)
logger = logging.getLogger()

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
            os.environ[keyvalue[0]] = keyvalue[1].replace('\n', '').replace(' ', '').replace('"', '')


def subprocess_run(args):
    try:
        completed_process = subprocess.run(args=args,
                                           stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE,
                                           text=True,
                                           check=True)
        return completed_process
    except CalledProcessError as cperror:
        logger.error(msg=f"{cperror.stdout}, {cperror.stderr}")
        logger.error(msg=traceback.format_exc())
        sys.exit(1)
    except Exception:
        logger.error(msg=traceback.format_exc())
        sys.exit(1)


def download_import_rhcos_ova():
    logging.info(msg="In download_import_rhcos_ova function...")
    branch = "release-4.14"
    rhcos_version = "rhcos-414"
    uri = f"https://raw.githubusercontent.com/openshift/installer/refs/heads/{branch}/data/data/coreos/rhcos.json"

    govc_ls_vm = subprocess_run(["govc", "ls", "-t", "VirtualMachine", "*"])

    if govc_ls_vm is not None:
        if govc_ls_vm.returncode == 0:
            if len(govc_ls_vm.stdout) != 0:
                for vmpath in govc_ls_vm.stdout.splitlines():
                    if rhcos_version in vmpath:
                        return vmpath

    with urllib.request.urlopen(uri) as url:
        data = json.load(url)
        ovaurl = data["architectures"]["x86_64"]["artifacts"]["vmware"]["formats"]["ova"]["disk"]["location"]

    subprocess_run(["curl", "-L", "-o", "/tmp/rhcos.ova", ovaurl])

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
    logger.critical("CLUSTER_PROFILE_NAME is undefined")
    sys.exit(1)

if leased_resource is None:
    logger.critical("failed to acquire lease")
    sys.exit(1)

logger.info("Converting shell script exports to environmental variables")

convert_shell_file_to_envvar(f"{shared_dir}/vsphere_context.sh")
convert_shell_file_to_envvar(f"{shared_dir}/govc.sh")

# Remove SSL CERT environmental variables
os.environ.pop("GOVC_TLS_CA_CERTS")
os.environ.pop("SSL_CERT_FILE")

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
    logger.warning("Using legacy subnets.json")
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
            hosts = list(ipaddress.IPv4Network(machineNetworkCidr).hosts())[10:127]
            for h in hosts:
                ipaddresses.append(str(h))
    else:
        hosts = list(ipaddress.IPv4Network(subnet_obj[prh][vlanid]["machineNetworkCidr"]).hosts())[10:127]
        for h in hosts:
            ipaddresses.append(str(h))

vips_file_name = f"{shared_dir}/vips.txt"

gateway = subnet_obj[prh][vlanid]["gateway"]
mask = subnet_obj[prh][vlanid]["mask"]
dns_server = subnet_obj[prh][vlanid]["dnsServer"]
external_lb_ip_address = subnet_obj[prh][vlanid]["ipAddresses"][2]
machine_cidr = subnet_obj[prh][vlanid]["machineNetworkCidr"]

with open(machine_cidr_filename, "w") as machine_cidr_file:
    logger.info(f"Creating machine cidr file: {machine_cidr}")
    machine_cidr_file.write(machine_cidr)

with open(vips_file_name, "w") as vip_file:
    logger.info(f"Creating vip address file {external_lb_ip_address}, {external_lb_ip_address}")
    vip_file.write(f"{external_lb_ip_address}\n{external_lb_ip_address}")

haproxy = '''
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
    {% if epname == "router-http" %}
        {% set health_check = "check" %}
    {% endif %}
backend {{ epname }}
  mode tcp
  balance roundrobin
  option tcp-check
  default-server verify none inter 10s downinter 5s rise 2 fall 3 slowstart 60s maxconn 250 maxqueue 256 weight 100
  
  {%- for ip in ipaddresses %}
  server {{ epname }}-{{ ip |replace(".", "-") }} {{ ip }}:{{ port }} {{ health_check }}
  {%- endfor %}
{%- endfor %}

# haproxy must have a new line at the end of the config

'''

logger.info(msg="Creating HAProxy configuration.")
env = Environment(autoescape=select_autoescape())
haproxy_template = env.from_string(source=haproxy)
haproxy_config = haproxy_template.render(endpoints=endpoints, ipaddresses=ipaddresses)
haproxy_config_path = "/tmp/haproxy.cfg"

with open(haproxy_config_path, "w") as hf:
    hf.write(haproxy_config)

logger.info(msg="Creating Butane configuration.")
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
        local: {haproxy_config_path.split('/')[-1]} 
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

butane_config_path = "/tmp/butane.cfg"
with open(butane_config_path, "w") as bf:
    bf.write(butane_config)

vm_template = download_import_rhcos_ova()

butane = subprocess_run(["butane", "-r", "-d", "/tmp", butane_config_path])
encoded_ign = base64.b64encode(gzip.compress(butane.stdout.encode()))

govc_ls_networks = subprocess_run(["govc", "ls", f"/{vsphere_datacenter}/network"])
r = re.compile(f".*{vlanid}$")
networks = list(filter(r.match, govc_ls_networks.stdout.splitlines()))

if len(networks) != 1:
    logger.critical(f"Network list has more than one item {networks}")
    sys.exit(1)

os.environ["GOVC_NETWORK"] = networks[0].split('/')[-1]

vsphere_portgroup_path = networks[0]

govc_clone = subprocess_run(["govc", "vm.clone", "-on=false", f"-dc=/{vsphere_datacenter}",
                             f"-ds=/{vsphere_datacenter}/datastore/{vsphere_datastore}",
                             f"-pool={vsphere_resource_pool}",
                             f"-vm={vm_template}", f"{lb_name}"])

subprocess_run(["govc",
                "vm.change", "-vm", lb_name,
                "-e", "guestinfo.ignition.config.data.encoding=gzip+base64"])

ip_config = f"ip={external_lb_ip_address}::{gateway}:{mask}:lb::none nameserver={dns_server}"
subprocess_run(["govc",
                "vm.change",
                "-vm", lb_name,
                "-e", f"guestinfo.afterburn.initrd.network-kargs={ip_config}"])

subprocess_run(["govc",
                "vm.change",
                "-vm", lb_name,
                "-e", f"guestinfo.ignition.config.data={encoded_ign.decode('utf-8')}"])

subprocess_run(["govc", "vm.network.change",
                "-dc", f"/{vsphere_datacenter}",
                "-vm", f"{lb_name}",
                "-net", f"{vsphere_portgroup_path}",
                "ethernet-0"])

subprocess_run(["govc", "vm.power", "-on", lb_name])

with open(f"{shared_dir}/external_lb", "w") as touch:
    touch.write("\n")
