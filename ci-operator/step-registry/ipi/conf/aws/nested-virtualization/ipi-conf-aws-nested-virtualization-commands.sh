#!/usr/bin/env bash

# Configure AWS compute nodes to enable nested virtualization via install-config.yaml
#
# This script modifies the install-config.yaml to add:
#   compute[*].platform.aws.cpuOptions.nestedVirtualization: Enabled

set -eu
set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ ! -f "${CONFIG}" ]]; then
  printf "ERROR: install-config.yaml not found at [%s]\n" "${CONFIG}"
  exit 1
fi

printf "Configuring nested virtualization in install-config.yaml...\n"

# Create a Python script to modify the YAML using yq-style patching
python3 <<EOF
import yaml
import sys

config_file = "${CONFIG}"

# Load the install-config.yaml
with open(config_file, 'r') as f:
    config = yaml.safe_load(f)

# Ensure compute section exists
if 'compute' not in config or not isinstance(config['compute'], list):
    print("ERROR: No compute section found in install-config.yaml", file=sys.stderr)
    sys.exit(1)

if len(config['compute']) == 0:
    print("No compute items configured")
    # Set the Machine Management API to ClusterAPI
    config['compute'].append( { 'management': 'ClusterAPI' } )

# Add cpuOptions.nestedVirtualization to each compute pool
pool_count = 0
for compute_pool in config['compute']:
    # Initialize platform section if it doesn't exist
    if 'platform' not in compute_pool:
        compute_pool['platform'] = {}

    # Initialize aws section if it doesn't exist
    if 'aws' not in compute_pool['platform']:
        compute_pool['platform']['aws'] = {}

    # Add cpuOptions
    if 'cpuOptions' not in compute_pool['platform']['aws']:
        compute_pool['platform']['aws']['cpuOptions'] = {}

    # Set nestedVirtualization to Enabled
    compute_pool['platform']['aws']['cpuOptions']['nestedVirtualization'] = 'Enabled'
    pool_count += 1

print(f"Enabled nested virtualization for {pool_count} compute pool(s)")

# Write the modified config back
with open(config_file, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("Nested virtualization configuration complete.")
EOF

if [[ $? -ne 0 ]]; then
  printf "ERROR: Failed to configure nested virtualization\n"
  exit 1
fi

printf "\nVerifying configuration was applied:\n"
yq-v4 eval '.compute[].platform.aws.cpuOptions.nestedVirtualization' "${CONFIG}"

cat "${CONFIG}"
