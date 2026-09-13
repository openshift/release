#!/bin/bash
set -euo pipefail

echo "=== GSM secrets mounted at ==="
echo "  /var/group_variables/all"
echo "  /var/group_variables/bastions"
echo "  /var/group_variables/hypervisors"
echo ""
echo "Sleeping for 3600s — attach to this pod to inspect the mounted secrets."

sleep 3600
