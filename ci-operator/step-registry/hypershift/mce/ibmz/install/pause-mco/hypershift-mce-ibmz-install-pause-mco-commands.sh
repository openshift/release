#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

echo "Pausing master and worker MachineConfigPools to prevent MCO rolling updates..."
echo "--- MCP status before pause ---"
oc get mcp

oc patch mcp master --type=merge -p '{"spec":{"paused":true}}'
echo "Master MCP paused"

oc patch mcp worker --type=merge -p '{"spec":{"paused":true}}'
echo "Worker MCP paused"

echo "MCO will not roll nodes for any new MachineConfigs (PSI karg, swap, etc.)"
echo "This prevents management cluster disruption during operator install and tests"
