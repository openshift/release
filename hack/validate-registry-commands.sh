#!/usr/bin/env bash
set -euo pipefail

# This script checks all shell scripts in the step registry and errors if shellcheck detects error or warning level syntax issues

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

registry_dir="${base_dir}/ci-operator/step-registry"

# High oc verbosity can include HTTP authentication headers and request bodies.
# In particular, it must never be used while handling registry credentials or
# Kubernetes Secrets in publicly retained Prow logs.
if unsafe_verbose_commands=$(grep -RInE --include='*-commands.sh' \
  'oc.*--(loglevel|v)(=|[[:space:]])([89]|[1-9][0-9]+)([^0-9]|$)' "${registry_dir}"); then
  echo "ERROR: high-verbosity oc commands can expose credentials in Prow logs:"
  echo "${unsafe_verbose_commands}"
  exit 1
fi

# MachineConfig stores the node registry auth file as an encoded contents.source.
# Diagnostic output may show the file metadata, but never its embedded contents.
if unsafe_kubelet_config_output=$(grep -RInF --include='*-commands.sh' \
  '.spec.config.storage.files' "${registry_dir}" \
  | grep -F '/var/lib/kubelet/config.json' \
  | grep -vF '| {path, mode, overwrite}'); then
  echo "ERROR: MachineConfig diagnostics can expose the embedded registry auth file:"
  echo "${unsafe_kubelet_config_output}"
  exit 1
fi

find "${registry_dir}" -name "*.sh" -print0 | xargs -0 -n1 shellcheck -S warning
