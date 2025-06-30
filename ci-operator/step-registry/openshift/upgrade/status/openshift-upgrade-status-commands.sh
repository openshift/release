#!/bin/bash
set -xeuo pipefail

echo "Displaying OpenShift upgrade status:"
OC_ENABLE_CMD_UPGRADE_STATUS=ture oc adm upgrade status