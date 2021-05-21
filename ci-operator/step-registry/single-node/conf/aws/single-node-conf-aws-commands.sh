#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

SINGLE_NODE_AWS_INSTANCE_TYPE="m5d.2xlarge"

echo "Updating install-config.yaml to a single ${SINGLE_NODE_AWS_INSTANCE_TYPE} control plane node and 0 workers"

pip3 install pyyaml --user
python3 -c '
import yaml
import sys

input_file = sys.argv[1]
output_file = sys.argv[2] if len(sys.argv) == 3 else sys.argv[1]  # Output in-place if destination not given

with open(input_file) as f:
    cfg = yaml.safe_load(f)

# Some workflows do not define controlPlane in install-config.yaml
if not "controlPlane" in cfg:
  cfg["controlPlane"] = {}

cfg["controlPlane"]["replicas"] = 1

# Single Node Openshift requires extra memory and compute resources
platform = cfg["controlPlane"]["platform"]
if "aws" in platform:
    platform["aws"]["type"] = "'${SINGLE_NODE_AWS_INSTANCE_TYPE}'"
else:
    raise ValueError("This step only applies to AWS, please use the correct step for your platform")

# Some workflows do not define any compute machine pools in install-config.yaml
if not "compute" in cfg:
    cfg["compute"] = [
        {
            "name": "worker",
            "platform": {},
        }
    ]

for machine_pool in cfg["compute"]:
    machine_pool["replicas"] = 0

with open(output_file, "w") as f:
    yaml.safe_dump(cfg, f)
' "${SHARED_DIR}/install-config.yaml"

