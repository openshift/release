#!/usr/bin/env python

import ansible_runner
import copy
from envbash import load_envbash
import json
import os
import sys
import yaml
import shutil 

def log(msg):
  print(msg)

def ip_to_ptr(ip_address):
    octets = ip_address.split(".")    
    reversed_octets = "-".join(reversed(octets))
    ptr_record = f"{reversed_octets}.in-addr.arpa"
    return ptr_record

try:
    from pylint.lint import Run
    file_path = os.path.realpath(__file__)
    Run([file_path], exit=False)
except ImportError:
    log("linter not available, run outside of CI")

log("provisioning a nested vCenter environment")

load_envbash('/var/run/vault/vsphere-ibmcloud-ci/nested-secrets.sh')

cluster_profile_name = os.environ.get("CLUSTER_PROFILE_NAME")
leased_resource = os.environ.get("LEASED_RESOURCE")
shared_dir = os.environ.get("SHARED_DIR")

artifact_dir = os.environ.get("ARTIFACT_DIR")
home = os.environ.get('HOME')

if cluster_profile_name is None:
    log("CLUSTER_PROFILE_NAME is undefined")
    sys.exit(1)

if cluster_profile_name != "vsphere-elastic":
    log("using legacy sibling of this step")
    sys.exit(0)

if leased_resource is None:
    log("failed to acquire lease")
    sys.exit(1)

with open(os.path.join(shared_dir, "LEASE_single.json")) as f:
    lease = json.load(f)

os.environ["VCPUS"]                         = str(lease["spec"]["vcpus"])
os.environ["MEMORY"]                        = str(lease["spec"]["memory"] * 1024)
os.environ["GOVC_CLUSTER"]                  = os.path.basename(lease["status"]["topology"]["computeCluster"])
os.environ["GOVC_DATACENTER"]               = lease["status"]["topology"]["datacenter"]
os.environ["GOVC_DATASTORE"]                = os.path.basename(lease["status"]["topology"]["datastore"])
os.environ["GOVC_NETWORK"]                  = os.path.basename(lease["status"]["topology"]["networks"][0])
os.environ["GOVC_URL"]                      = lease["status"]["server"]
os.environ["GOVC_USERNAME"]                 = os.environ["vcenter_username"]
os.environ["GOVC_PASSWORD"]                 = os.environ["vcenter_password"]
os.environ["NESTED_PASSWORD"]               = os.environ["vcenter_password"]
os.environ["HOSTS_PER_FAILURE_DOMAIN"]      = os.environ["HOSTS"]
os.environ["CLUSTER_NAME"]                  = f'{os.environ["NAMESPACE"]}-{os.environ["UNIQUE_HASH"]}'

ara_dir                                     = f'{artifact_dir}/ara'
os.makedirs(ara_dir, exist_ok=True)


for key in os.environ:
    if "password" in key.lower():
        continue
    print(f"export {key}={os.environ[key]}")

os.environ["ANSIBLE_TASK_TIMEOUT"] = str(20 * 60)

if os.environ["VCENTER_VERSION"] == "7":
    vcenter_version="VC7.0.3.01400-21477706-ESXi7.0u3q"
else:
    vcenter_version="VC8.0.2.00100-22617221-ESXi8.0u2c"

try:
    r = ansible_runner.run_command(
        executable_cmd='ansible-playbook',
        cmdline_args=['main.yml', '-i', 'hosts', '--extra-var', 'version=%s' %vcenter_version,'-vvvvvv', '-k'],
        input_fd=sys.stdin,
        output_fd=sys.stdout,
        error_fd=sys.stdout,
        )

    print(r)

finally:
    # Copy ara's sqlite db to artifacts
    ara_sql = f"{home}/.ara/server/ansible.sqlite"
    shutil.copy2(ara_sql, ara_dir)


with open(os.path.join(shared_dir, "vips.txt"), "r") as vip_file:
    vips = vip_file.readlines()

with open(os.path.join(shared_dir, "nested-inventory.json")) as inventory_file:
    inventory = json.load(inventory_file)

with open(os.path.join(shared_dir, "nested-ansible-platform.yaml")) as inventory_file:
    nested_platform = yaml.safe_load(inventory_file)

with open(os.path.join(shared_dir, "install-config.yaml")) as install_config_file:
    install_config = yaml.safe_load(install_config_file)

install_config["platform"] = copy.deepcopy(nested_platform["platform"])

for vcenter in nested_platform["platform"]["vsphere"]["vcenters"]:
    server = vcenter["server"]
    if server not in inventory:
        log(f"{server} not found in ansible inventory. this is probably a bug in the ansible.")
    
    vcenter_ip = inventory[vcenter["server"]]["NESTEDVMIP"]
    ptr_record = ip_to_ptr(vcenter_ip)
    
    for ic_vcenter in install_config["platform"]["vsphere"]["vcenters"]:
        if ic_vcenter["server"] == server:
            ic_vcenter["user"] = "administrator@vsphere.local"
            ic_vcenter["password"] = os.environ["vcenter_password"]
            ic_vcenter["server"] = ptr_record

    for ic_failure_domain in install_config["platform"]["vsphere"]["failureDomains"]:
        if ic_failure_domain["server"] == server:
            ic_failure_domain["server"] = ptr_record
        ic_failure_domain["topology"]["networks"] = [os.environ["GOVC_NETWORK"]]

install_config["platform"]["vsphere"]["apiVIP"] = vips[0].strip()
if len(vips) == 1:
    install_config["platform"]["vsphere"]["ingressVIP"] = vips[0].strip()
else:
    install_config["platform"]["vsphere"]["ingressVIP"] = vips[1].strip()


with open(os.path.join(shared_dir, "platform.json"), "w") as platform_json_file:
    json.dump(install_config["platform"]["vsphere"], platform_json_file, indent=2)

with open(os.path.join(shared_dir, "platform.yaml"), "w") as platform_yaml_file:
    platform_yaml = yaml.dump(install_config["platform"]["vsphere"], indent=2)
    for line in platform_yaml.splitlines():
        platform_yaml_file.write(f"    {line}\n")

with open(os.path.join(shared_dir, "install-config.yaml"), "w") as install_config_file:
    yaml.dump(install_config, install_config_file)


