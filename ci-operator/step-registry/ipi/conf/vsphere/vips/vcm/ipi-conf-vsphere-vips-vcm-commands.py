#!/usr/bin/env python

import os
import sys
import json

try:
    from pylint.lint import Run
    file_path = os.path.realpath(__file__)
    Run([file_path], exit=False)
except ImportError:
    print("linter not available, run outside of CI")


cluster_profile_name = os.environ.get("CLUSTER_PROFILE_NAME")
leased_resource = os.environ.get("LEASED_RESOURCE")
shared_dir = os.environ.get("SHARED_DIR")

if cluster_profile_name is None:
    print("CLUSTER_PROFILE_NAME is undefined")
    sys.exit(1)

if cluster_profile_name != "vsphere-elastic":
    print("using legacy sibling of this step")
    sys.exit(0)

if leased_resource is None:
    print("failed to acquire lease")
    sys.exit(1)

subnets_config = shared_dir + "/NETWORK_single.json"
machine_cidr_filename = shared_dir + "/machinecidr.txt"
vips_file_name = shared_dir + "/vips.txt"

with open(subnets_config) as f:
    subnet_obj = json.load(f)

    machine_cidr = subnet_obj["spec"]["machineNetworkCidr"]
    api_vip = subnet_obj["spec"]["ipAddresses"][2]
    ingress_vip = subnet_obj["spec"]["ipAddresses"][3]

    with open(vips_file_name, "w") as vip_file:
        print("vip addresses {} {}".format(api_vip, ingress_vip))
        vip_file.write("{}\n{}".format(api_vip, ingress_vip))

    with open(machine_cidr_filename, "w") as machine_cidr_file:
        print("machine cidr {}".format(machine_cidr))
        machine_cidr_file.write(machine_cidr)
