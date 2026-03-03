#!/bin/bash
# Day 0: Copies host list into SHARED_DIR/hosts.yaml for gs-baremetal-conf and gs-baremetal-orchestrate.
# Source: HOSTS_SOURCE_PATH (file or dir/hosts.yaml) or BW_PATH/hosts.yaml.
# Use when host data is in a credential mount (e.g. from BitWarden note "BMC" field saved as hosts.yaml).
set -euxo pipefail; shopt -s inherit_errexit

typeset src="${HOSTS_SOURCE_PATH:-}"
if [[ -z "${src}" ]]; then
  typeset bwPath="${BW_PATH:-/bw}"
  src="${bwPath}/hosts.yaml"
fi
[[ -f "${src}" ]] || { printf '%s\n' "Hosts file not found at ${src}. Set HOSTS_SOURCE_PATH or provide ${src} via credential mount." 1>&2; exit 1; }

cp -f "${src}" "${SHARED_DIR}/hosts.yaml"
printf '%s\n' "Copied ${src} to SHARED_DIR/hosts.yaml."
echo "hosts_source=${src}" > "${ARTIFACT_DIR}/fetch-hosts-source.txt" 2>/dev/null || true

true
