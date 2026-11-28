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

# Behavioral tests that intentionally live outside the step registry, because
# registry validation only accepts registered step files. Keep this list in
# step with the suites under hack/tests; every entry must be tracked in HEAD.
behavioral_tests=(
  "hack/tests/github-downstream-sync-commands_test.sh"
  "hack/tests/rosa-gap-analysis-cluster-install-delete-metrics_test.sh"
  "hack/tests/validate-registry-commands_test.sh"
)

# Paths this invocation restored or created, newest last. Only these are
# removed on exit: anything already on disk is left exactly as it was found.
restored_test_files=()
created_test_dirs=()

cleanup_restored_tests() {
  local path index
  # ${arr[@]+...} because bash before 4.4 treats an empty array's [@] as
  # unbound under `set -u`, and `|| true` because a cleanup that fails must
  # neither abort the rest of the cleanup nor overwrite the real exit status.
  for path in ${restored_test_files[@]+"${restored_test_files[@]}"}; do
    rm -f "${path}" || true
  done
  # Deepest first, so a directory is only removed once its children are gone.
  # rmdir, never rm -r: a directory that is not empty was not ours alone.
  for ((index = ${#created_test_dirs[@]} - 1; index >= 0; index--)); do
    rmdir "${created_test_dirs[index]}" 2>/dev/null || true
  done
}
# One handler for every suite: a second `trap ... EXIT` would silently replace
# this one and leak whatever the first had registered.
trap cleanup_restored_tests EXIT

# Prow derives sparse-checkout paths from the base branch configuration, so a
# test added by the PR can exist in HEAD while still being absent from disk.
# Restore it rather than skipping: a suite that never ran must not look like a
# suite that passed. A test missing from HEAD is a repository error, not a
# checkout artifact, and fails the run.
restore_test_from_head() {
  local relative_path="$1"
  local test_path="${base_dir}/${relative_path}"
  local test_dir probe level
  local missing_dirs=()

  if ! git -C "${base_dir}" cat-file -e "HEAD:${relative_path}"; then
    echo "ERROR: ${relative_path} does not exist in HEAD" >&2
    exit 1
  fi

  # -L as well as -e: a dangling symlink is not -e, and writing through it
  # would create a file outside the recorded set and then delete the link.
  if [[ -e "${test_path}" || -L "${test_path}" ]]; then
    return 0
  fi

  test_dir="$(dirname "${test_path}")"
  if [[ ! -d "${test_dir}" ]]; then
    # Record every level this invocation creates, shallowest first, so cleanup
    # removes exactly those and no pre-existing parent.
    # ${arr[@]+...} because bash before 4.4 treats an empty array's [@] as
    # unbound under `set -u`, and this prepend runs with missing_dirs empty on
    # its first iteration.
    probe="${test_dir}"
    while [[ ! -d "${probe}" ]]; do
      missing_dirs=("${probe}" ${missing_dirs[@]+"${missing_dirs[@]}"})
      probe="$(dirname "${probe}")"
    done
    # One level at a time, shallowest first, each recorded as soon as it
    # exists: `mkdir -p` followed by a single registration would leave an
    # already-created parent untracked if a deeper level then failed.
    for level in ${missing_dirs[@]+"${missing_dirs[@]}"}; do
      mkdir "${level}"
      created_test_dirs+=("${level}")
    done
  fi

  # Registered before the write, not after: `git show` creates the destination
  # before it can fail, and a failed chmod leaves it behind too. Either way the
  # EXIT handler must know the file is ours, or a partial restore survives and
  # the existence check above would accept it on a later run.
  restored_test_files+=("${test_path}")
  git -C "${base_dir}" show "HEAD:${relative_path}" > "${test_path}"
  chmod 0755 "${test_path}"
}

for behavioral_test in "${behavioral_tests[@]}"; do
  restore_test_from_head "${behavioral_test}"
  shellcheck -S warning "${base_dir}/${behavioral_test}"
  # Through bash, not directly: the file mode is not a contract these suites
  # are meant to assert, and a suite committed 0644 would otherwise fail with
  # an opaque "Permission denied" instead of running.
  bash "${base_dir}/${behavioral_test}"
done
