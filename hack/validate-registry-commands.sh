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

# Behavioral tests for step-registry scripts intentionally live outside the step
# registry because registry validation only accepts registered step files.
tests_dir_rel="hack/tests"
tests_dir="${base_dir}/${tests_dir_rel}"
created_tests=()
created_tests_dir=false

cleanup_materialized_tests() {
  local created_test
  for created_test in ${created_tests+"${created_tests[@]}"}; do
    rm -f "${created_test}"
  done
  if [[ "${created_tests_dir}" == true ]]; then
    rmdir "${tests_dir}" 2>/dev/null || true
  fi
}
trap cleanup_materialized_tests EXIT

if ! git -C "${base_dir}" rev-parse --verify --quiet "HEAD:${tests_dir_rel}" > /dev/null; then
  echo "ERROR: ${tests_dir_rel} does not exist in HEAD" >&2
  exit 1
fi

test_names=()
while IFS= read -r test_name; do
  test_names+=("${test_name}")
done < <(git -C "${base_dir}" ls-tree --name-only "HEAD:${tests_dir_rel}" | grep -E '_test\.sh$' | sort)

if (( ${#test_names[@]} == 0 )); then
  echo "ERROR: no ${tests_dir_rel}/*_test.sh files exist in HEAD" >&2
  exit 1
fi

# Run every check of every test even when one fails, so a single failure does not hide
# the others. `set -e` would stop at the first one, so each check is guarded.
failed_checks=()
for test_name in "${test_names[@]}"; do
  test_path="${tests_dir}/${test_name}"
  # Prow derives sparse-checkout paths from the base branch configuration, so a
  # test added by the PR can exist in HEAD while still being absent from disk.
  if [[ ! -e "${test_path}" ]]; then
    if [[ ! -d "${tests_dir}" ]]; then
      mkdir -p "${tests_dir}"
      created_tests_dir=true
    fi
    created_tests+=("${test_path}")
    if ! git -C "${base_dir}" show "HEAD:${tests_dir_rel}/${test_name}" > "${test_path}" \
      || ! chmod 0755 "${test_path}"; then
      failed_checks+=("restore:${test_name}")
      continue
    fi
  fi

  if ! shellcheck -S warning "${test_path}"; then
    failed_checks+=("shellcheck:${test_name}")
  fi
  echo "Running ${tests_dir_rel}/${test_name}"
  if ! "${test_path}"; then
    failed_checks+=("test:${test_name}")
  fi
done

if (( ${#failed_checks[@]} > 0 )); then
  echo "ERROR: failing checks: ${failed_checks[*]}" >&2
  exit 1
fi
