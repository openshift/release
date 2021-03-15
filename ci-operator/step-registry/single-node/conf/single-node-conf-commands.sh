#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

SINGLE_NODE_AWS_INSTANCE_TYPE="m5d.2xlarge"

echo "Install config before single-node config patch:"
cat "${SHARED_DIR}/install-config.yaml"

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
assert "aws" in cfg["controlPlane"]["platform"], "Only AWS single-node is supported for now"
cfg["controlPlane"]["platform"]["aws"]["type"] = "'${SINGLE_NODE_AWS_INSTANCE_TYPE}'"

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

echo "Install config after single-node config patch:"
cat "${SHARED_DIR}/install-config.yaml"
