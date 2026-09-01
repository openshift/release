#!/bin/bash
set -euo pipefail

remote_host=$(<"${CLUSTER_PROFILE_DIR}/remote-host")

ping -c 5 "${remote_host}"
