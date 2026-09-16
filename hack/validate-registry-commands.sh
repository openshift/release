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

# install-config may contain credentials in the httpProxy and httpsProxy values.
# Every use of the established sensitive-field filter must omit those fields too.
if unsafe_install_config_filters=$(grep -RInF --include='*-commands.sh' \
  'password\|username\|pullSecret' "${registry_dir}" \
  | grep -F 'install-config.yaml' \
  | grep -vF 'httpProxy\|httpsProxy'); then
  echo "ERROR: install-config diagnostics must omit proxy credential fields:"
  echo "${unsafe_install_config_filters}"
  exit 1
fi

# ${SHARED_DIR}/proxy-conf.sh exports HTTP_PROXY, and some writers inline
# credentials into the proxy URL. Sourcing it runs those exports in the current
# shell, so under `set -x` each one is echoed with the password expanded into
# the publicly retained Prow log. Require `set +x` immediately before the source.
# Only an unindented `set -x` counts as enabling xtrace for the rest of the
# script; an indented one is inside a function, subshell or conditional and says
# nothing about the state at the source.
if unguarded_proxy_conf=$(find "${registry_dir}" -name '*-commands.sh' -print0 \
  | xargs -0 awk '
      FNR == 1 { xtrace = 0; prev = "" }
      { line = $0; sub(/^[[:space:]]+/, "", line) }
      /^set[[:space:]]+-[abefhkmnptuvz]*x/ || /^set[[:space:]]+-o[[:space:]]+xtrace/ { xtrace = 1 }
      /^set[[:space:]]+\+[abefhkmnptuvz]*x/ { xtrace = 0 }
      line ~ /^(source|\.)[[:space:]].*proxy-conf\.sh/ && xtrace && prev != "set +x" {
        print FILENAME ":" FNR ": " line
      }
      line != "" && line !~ /^#/ { prev = line }
  ' | grep .); then
  echo "ERROR: sourcing proxy-conf.sh while xtrace may be on can expose the proxy password in Prow logs."
  echo "Bracket the source with 'set +x' and 'set -x':"
  echo "${unguarded_proxy_conf}"
  exit 1
fi

find "${registry_dir}" -name "*.sh" -print0 | xargs -0 -n1 shellcheck -S warning
