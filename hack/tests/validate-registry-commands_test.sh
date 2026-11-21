#!/bin/bash

# Behavioral tests for hack/validate-registry-commands.sh, specifically its
# recovery of behavioral test files that are tracked in HEAD but absent from
# disk. Prow derives sparse-checkout paths from the base branch configuration,
# so a test added by a PR can exist in HEAD and still not be checked out.
#
# Regression guarded: the gap-analysis suite used to be wrapped in a plain
# `[[ -e ... ]]` guard, so an absent file made the wrapper skip the suite and
# exit 0 -- a suite that never ran looked exactly like a suite that passed.
#
# Each case runs the real wrapper against a throwaway git fixture whose step
# registry holds a single trivial script, so no case walks the real registry
# and nothing here depends on a cluster, credentials or the network. The
# fixture's hack/tests holds stub suites that record a marker when they run,
# which is how these cases tell "recovered and executed" from "recovered".
#
# The fixture stubs cover every path in the wrapper's behavioral_tests list,
# including this file's own path. The wrapper under test therefore runs the
# fixture's stub, never this script again, so there is no recursion. Adding a
# suite to that list without adding it to FIXTURE_TESTS below makes these
# cases fail with "does not exist in HEAD", which is the intended signal.

set -o nounset
set -o errexit
set -o pipefail

SUITE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# WRAPPER_UNDER_TEST lets the suite be pointed at another copy of the wrapper,
# which is how the regression was confirmed against the pre-fix version.
WRAPPER="${WRAPPER_UNDER_TEST:-${REPO_ROOT}/hack/validate-registry-commands.sh}"
# Resolved here, before any case changes directory: case 11 re-execs this suite
# from inside a sacrificial repository, and a relative override would make the
# child report "wrapper not found" and fail the isolation check for an
# unrelated reason. An already-absolute path is unchanged.
if [[ "${WRAPPER}" != /* ]]; then
  WRAPPER="$(cd "$(dirname "${WRAPPER}")" && pwd)/$(basename "${WRAPPER}")"
fi
export WRAPPER_UNDER_TEST="${WRAPPER}"

if [[ ! -f "${WRAPPER}" ]]; then
  echo "FATAL: wrapper not found: ${WRAPPER}" >&2
  exit 1
fi

for tool in git shellcheck; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "SKIP: ${tool} is not available; skipping wrapper tests" >&2
    exit 0
  fi
done

# Every suite the wrapper expects to find, with the marker each stub records.
FIXTURE_TESTS=(
  "hack/tests/github-downstream-sync-commands_test.sh:downstream"
  "hack/tests/rosa-gap-analysis-cluster-install-delete-metrics_test.sh:gap"
  "hack/tests/validate-registry-commands_test.sh:wrapper"
)

# Repository-local Git overrides would point every `git -C "${dir}"` below at
# the caller's repository instead of the fixture, so fixture setup could
# rewrite the caller's config, index or HEAD. Clear them for this process, so
# fixture setup, the wrapper subprocess and case 9 all inherit a clean
# environment. Global and system config are neutralised too, so a developer's
# core.excludesFile or core.hooksPath cannot decide what a fixture contains.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_TEMPLATE_DIR
# GIT_CONFIG_COUNT and its indexed key/value pairs are config overrides that
# apply to every git invocation, so neutralising the global and system files is
# not enough on its own. The variables that exist are enumerated rather than
# derived from the counter: an orphan pair left behind by GIT_CONFIG_COUNT=0
# would survive a count-driven loop, and a value like "08" or "many" would be
# an arithmetic error or unbounded work rather than a bound.
unset GIT_CONFIG_COUNT
for _git_config_var in $(compgen -v GIT_CONFIG_KEY_ || true) \
                       $(compgen -v GIT_CONFIG_VALUE_ || true); do
  unset "${_git_config_var}"
done
unset _git_config_var
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0
WORKROOT="$(mktemp -d)"
trap 'rm -rf "${WORKROOT}"' EXIT

# make_fixture [failing_marker] -> sets FIXTURE to the fixture directory.
# Deliberately not called through command substitution: that runs in a subshell
# which does not inherit errexit, so a failed mktemp would leave an empty path
# and every `git -C ""` below would act on whatever repository the caller
# happens to be sitting in. Called directly, a failure stops the suite here.
# Builds a git repository the wrapper accepts: a one-script step registry and
# a committed stub for every suite in FIXTURE_TESTS. When $1 names a marker,
# that stub records its marker and then exits 1, so a suite can fail after it
# has demonstrably run.
FIXTURE=""
make_fixture(){
  local failing_marker="${1:-}"
  local entry path marker dir
  # mktemp, not a counter: a counter would have to survive across calls, and
  # a shared fixture would let one case read another's repository state.
  dir="$(mktemp -d "${WORKROOT}/fixture-XXXXXX")"
  if [[ -z "${dir}" || ! -d "${dir}" ]]; then
    echo "FATAL: could not create a fixture directory under ${WORKROOT}" >&2
    exit 1
  fi
  mkdir -p "${dir}/ci-operator/step-registry/example" "${dir}/hack/tests" "${dir}/markers"

  cat > "${dir}/ci-operator/step-registry/example/example-commands.sh" <<'STEP'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
echo "example step"
STEP

  for entry in "${FIXTURE_TESTS[@]}"; do
    path="${entry%%:*}"
    marker="${entry##*:}"
    {
      echo '#!/bin/bash'
      echo 'set -o nounset'
      echo 'set -o errexit'
      echo 'set -o pipefail'
      echo ': "${MARKER_DIR:?MARKER_DIR must be set}"'
      echo "echo ran > \"\${MARKER_DIR}/${marker}\""
      if [[ "${marker}" == "${failing_marker}" ]]; then
        echo 'echo "stub suite failing on purpose" >&2'
        # 23, not 1: a wrapper that collapsed every suite failure into a
        # generic 1 would still satisfy a mere "non-zero" assertion.
        echo 'exit 23'
      fi
    } > "${dir}/${path}"
    chmod 0755 "${dir}/${path}"
  done

  # Every git call is silenced: fixture setup has nothing to say on success,
  # and git's own chatter would bury a real failure.
  git -C "${dir}" init -q >/dev/null
  git -C "${dir}" config user.email ci@example.com >/dev/null
  git -C "${dir}" config user.name "CI Fixture" >/dev/null
  # -f: a global core.excludesFile must not decide what the fixture commits.
  git -C "${dir}" add -A -f >/dev/null
  # core.hooksPath=/dev/null as well as commit.gpgsign=false: disabling signing
  # does not disable hooks, and a commit-msg hook that rejects "fixture" would
  # leave the fixture with no HEAD, so the wrapper would report missing suites
  # instead of exercising restoration.
  git -C "${dir}" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m "fixture" >/dev/null
  FIXTURE="${dir}"
}

# Installs a pass-through git that fails the gap-analysis `git show`. The
# wrapper's shell creates the destination for the redirect before git runs, so
# the file exists even though the restore failed: exactly the case where the
# EXIT handler must already own it.
install_failing_git_show(){
  local dir="$1" real_git
  real_git="$(printf '%q' "$(command -v git)")"
  mkdir -p "${dir}/bin"
  cat > "${dir}/bin/git" <<GIT
#!/bin/bash
if [[ "\$*" == *"show HEAD:${GAP_REL}"* ]]; then
  printf '#!/bin/bash\n# truncated restore'
  echo "git: simulated failure after opening the destination" >&2
  exit 1
fi
exec ${real_git} "\$@"
GIT
  chmod 0755 "${dir}/bin/git"
  bash -n "${dir}/bin/git"
}

# Installs a pass-through mkdir that fails only on the deeper level, so the
# wrapper creates hack and then cannot create hack/tests: the level it did
# create must still be recorded and removed.
install_failing_mkdir(){
  local dir="$1" real_mkdir
  real_mkdir="$(printf '%q' "$(command -v mkdir)")"
  mkdir -p "${dir}/bin"
  cat > "${dir}/bin/mkdir" <<MKDIR
#!/bin/bash
# Emulates what a real mkdir -p does when only the deepest level is refused:
# the parents it already created stay on disk, and it exits non-zero.
parents=false
for arg in "\$@"; do
  [[ "\${arg}" == "-p" ]] && parents=true
done
for arg in "\$@"; do
  if [[ "\${arg}" == */hack/tests ]]; then
    if [[ "\${parents}" == true ]]; then
      ${real_mkdir} -p "\$(dirname "\${arg}")"
    fi
    echo "mkdir: simulated failure creating \${arg}" >&2
    exit 1
  fi
done
exec ${real_mkdir} "\$@"
MKDIR
  chmod 0755 "${dir}/bin/mkdir"
  bash -n "${dir}/bin/mkdir"
}

# run_wrapper <fixture> -> sets RC and MARKERS
run_wrapper(){
  local dir="$1"
  rm -rf "${dir}/markers"
  mkdir -p "${dir}/markers"
  local wrapper_path="${PATH}"
  if [[ -d "${dir}/bin" ]]; then
    wrapper_path="${dir}/bin:${PATH}"
  fi
  set +o errexit
  MARKER_DIR="${dir}/markers" PATH="${wrapper_path}" "${WRAPPER}" "${dir}" \
    > "${dir}/stdout.log" 2> "${dir}/stderr.log"
  RC=$?
  set -o errexit
  MARKERS="${dir}/markers"
  STDERR="${dir}/stderr.log"
}

ran(){ [[ -f "${MARKERS}/$1" ]]; }
did_not_run(){ [[ ! -f "${MARKERS}/$1" ]]; }
rc_is(){ [[ "${RC}" -eq "$1" ]]; }
rc_nonzero(){ [[ "${RC}" -ne 0 ]]; }
path_exists(){ [[ -e "$1" ]]; }
path_absent(){ [[ ! -e "$1" && ! -L "$1" ]]; }
path_is_symlink(){ [[ -L "$1" ]]; }
stderr_has(){ grep -qF "$1" "${STDERR}"; }

check(){
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

# Asserted in every run, including the child of case 11, which deliberately
# exports these before re-executing the suite. In a clean parent this is
# trivially true; in that child it is the only thing that proves the clearing
# above actually happened.
inherited_git_overrides_cleared(){
  local leftover
  [[ -z "${GIT_DIR:-}" && -z "${GIT_WORK_TREE:-}" && -z "${GIT_INDEX_FILE:-}" \
     && -z "${GIT_CONFIG_COUNT:-}" && -z "${GIT_TEMPLATE_DIR:-}" \
     && "${GIT_CONFIG_GLOBAL:-}" == "/dev/null" \
     && "${GIT_CONFIG_SYSTEM:-}" == "/dev/null" ]] || return 1
  # Every pair, not just index 0: the clearing enumerates the variables that
  # exist, so the assertion has to do the same or it only half-checks it.
  leftover="$( { compgen -v GIT_CONFIG_KEY_ || true; compgen -v GIT_CONFIG_VALUE_ || true; } | tr '\n' ' ')"
  [[ -z "${leftover// /}" ]]
}
echo "case: inherited Git overrides are cleared in this process"
check "no repository, index or config override survives" inherited_git_overrides_cleared

GAP_REL="hack/tests/rosa-gap-analysis-cluster-install-delete-metrics_test.sh"
DOWNSTREAM_REL="hack/tests/github-downstream-sync-commands_test.sh"

###########################################
# (1) Every suite is already on disk.
###########################################
echo "case: all suites present on disk"
make_fixture
fixture="${FIXTURE}"
run_wrapper "${fixture}"
check "wrapper exits zero" rc_is 0
check "downstream suite ran" ran downstream
check "gap-analysis suite ran" ran gap
check "wrapper suite ran" ran wrapper
check "pre-existing gap test left in place" path_exists "${fixture}/${GAP_REL}"
check "pre-existing downstream test left in place" path_exists "${fixture}/${DOWNSTREAM_REL}"

###########################################
# (2) Only the gap-analysis suite is missing from disk. This is the regression:
# it must be recovered from HEAD and run, not skipped.
###########################################
echo "case: gap-analysis suite missing from disk"
make_fixture
fixture="${FIXTURE}"
rm -f "${fixture}/${GAP_REL}"
run_wrapper "${fixture}"
check "wrapper exits zero" rc_is 0
check "gap-analysis suite actually ran" ran gap
check "downstream suite still ran" ran downstream
check "recovered gap test removed again" path_absent "${fixture}/${GAP_REL}"
check "pre-existing downstream test untouched" path_exists "${fixture}/${DOWNSTREAM_REL}"
check "shared directory kept, it was not ours" path_exists "${fixture}/hack/tests"

###########################################
# (3) Every suite and the shared directory are missing.
###########################################
echo "case: all suites and hack/tests missing"
make_fixture
fixture="${FIXTURE}"
rm -rf "${fixture}/hack/tests"
run_wrapper "${fixture}"
check "wrapper exits zero" rc_is 0
check "downstream suite ran" ran downstream
check "gap-analysis suite ran" ran gap
check "wrapper suite ran" ran wrapper
check "recovered gap test removed again" path_absent "${fixture}/${GAP_REL}"
check "recovered downstream test removed again" path_absent "${fixture}/${DOWNSTREAM_REL}"
check "directory this run created is removed" path_absent "${fixture}/hack/tests"
check "pre-existing parent directory kept" path_exists "${fixture}/hack"

###########################################
# (4) The shared directory exists but is empty: it is not ours to remove.
###########################################
echo "case: hack/tests pre-exists and is empty"
make_fixture
fixture="${FIXTURE}"
rm -f "${fixture}/hack/tests/"*
run_wrapper "${fixture}"
check "wrapper exits zero" rc_is 0
check "gap-analysis suite ran" ran gap
check "recovered files removed again" path_absent "${fixture}/${GAP_REL}"
check "pre-existing directory retained" path_exists "${fixture}/hack/tests"

###########################################
# (5) A recovered suite fails. The wrapper must fail with it and still clean up
# only what it restored, without masking the failure.
###########################################
echo "case: recovered gap-analysis suite fails"
make_fixture gap
fixture="${FIXTURE}"
rm -f "${fixture}/${GAP_REL}"
run_wrapper "${fixture}"
check "wrapper propagates the suite's exit status" rc_is 23
check "the failing suite did run" ran gap
check "recovered gap test removed again" path_absent "${fixture}/${GAP_REL}"
check "pre-existing downstream test untouched" path_exists "${fixture}/${DOWNSTREAM_REL}"

###########################################
# (6) A suite fails before a later suite is recovered: cleanup still removes
# what was restored, and nothing is left half-recovered.
###########################################
echo "case: first suite fails before later suites are recovered"
make_fixture downstream
fixture="${FIXTURE}"
rm -rf "${fixture}/hack/tests"
run_wrapper "${fixture}"
check "wrapper propagates the suite's exit status" rc_is 23
check "the failing suite did run" ran downstream
check "the later suite did not run" did_not_run gap
check "restored downstream test removed again" path_absent "${fixture}/${DOWNSTREAM_REL}"
check "later suite not left behind" path_absent "${fixture}/${GAP_REL}"
check "directory this run created is removed" path_absent "${fixture}/hack/tests"

###########################################
# (7) Nested levels: the shared directory and its parent are both absent, so
# recovery creates two levels and cleanup must remove exactly those two.
###########################################
echo "case: hack and hack/tests both missing"
make_fixture
fixture="${FIXTURE}"
rm -rf "${fixture}/hack"
run_wrapper "${fixture}"
check "wrapper exits zero" rc_is 0
check "downstream suite ran" ran downstream
check "gap-analysis suite ran" ran gap
check "both created levels are removed" path_absent "${fixture}/hack"

###########################################
# (8) A dangling symlink sits where a suite belongs. It is not -e, so without
# the -L guard recovery would write through it, creating a file outside the
# recorded set and then deleting a link this run never created. The wrapper
# must fail loudly and destroy nothing.
###########################################
echo "case: dangling symlink where the gap-analysis suite belongs"
make_fixture
fixture="${FIXTURE}"
mkdir -p "${fixture}/elsewhere"
rm -f "${fixture}/${GAP_REL}"
ln -s ../../elsewhere/gap.sh "${fixture}/${GAP_REL}"
run_wrapper "${fixture}"
check "wrapper exits non-zero" rc_nonzero
check "the pre-existing symlink is left alone" path_is_symlink "${fixture}/${GAP_REL}"
check "nothing was written through the link" path_absent "${fixture}/elsewhere/gap.sh"

###########################################
# (9) The restore itself fails after the destination has been created. The
# partial file must be removed, not left for a later run's existence check to
# accept as a real suite.
###########################################
echo "case: git show fails after creating the destination"
make_fixture
fixture="${FIXTURE}"
rm -f "${fixture}/${GAP_REL}"
install_failing_git_show "${fixture}"
run_wrapper "${fixture}"
check "wrapper exits non-zero" rc_nonzero
check "the partial restore is removed" path_absent "${fixture}/${GAP_REL}"
check "the failing suite did not run" did_not_run gap
check "earlier suites still ran" ran downstream

###########################################
# (9b) The shallower level is created and the deeper one then fails. The level
# that was created must already be recorded, so cleanup removes it.
###########################################
echo "case: mkdir fails after creating the shallower level"
make_fixture
fixture="${FIXTURE}"
rm -rf "${fixture}/hack"
install_failing_mkdir "${fixture}"
run_wrapper "${fixture}"
check "wrapper exits non-zero" rc_nonzero
check "the level that was created is removed" path_absent "${fixture}/hack"
check "no suite ran" did_not_run downstream

###########################################
# (10) A suite missing from HEAD is a repository error, not a checkout artifact.
###########################################
echo "case: gap-analysis suite missing from HEAD"
make_fixture
fixture="${FIXTURE}"
git -C "${fixture}" rm -q --cached "${GAP_REL}" >/dev/null
git -C "${fixture}" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -q -m "drop gap test" >/dev/null
rm -f "${fixture}/${GAP_REL}"
run_wrapper "${fixture}"
check "wrapper exits non-zero" rc_is 1
check "the missing suite is named" stderr_has "${GAP_REL} does not exist in HEAD"
check "suites before it still ran" ran downstream
check "the missing suite did not run" did_not_run gap
check "nothing left behind for the missing suite" path_absent "${fixture}/${GAP_REL}"

###########################################
# (11) A caller that exports repository-local Git variables for its own
# checkout must not have that checkout written to. Proven against a
# sacrificial repository with a sentinel config, index and HEAD -- never
# against the real one -- by re-running this suite from inside it with those
# variables exported. The child is marked so it does not recurse.
###########################################
if [[ -z "${WRAPPER_TEST_CHILD:-}" ]]; then
  echo "case: hostile inherited Git environment cannot touch the caller's repository"
  sacrificial="$(mktemp -d "${WORKROOT}/sacrificial-XXXXXX")"
  git -C "${sacrificial}" init -q >/dev/null
  git -C "${sacrificial}" config user.email sentinel@example.com >/dev/null
  git -C "${sacrificial}" config user.name SENTINEL >/dev/null
  echo sentinel > "${sacrificial}/tracked.txt"
  git -C "${sacrificial}" add -A -f >/dev/null
  git -C "${sacrificial}" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m sentinel >/dev/null
  echo staged > "${sacrificial}/staged.txt"
  git -C "${sacrificial}" add -A -f >/dev/null

  before_head="$(git -C "${sacrificial}" rev-parse HEAD)"
  before_name="$(git -C "${sacrificial}" config user.name)"
  before_index="$(git -C "${sacrificial}" diff --cached --name-only | sort | tr '\n' ' ')"

  set +o errexit
  (
    cd "${sacrificial}" || exit 1
    export WRAPPER_TEST_CHILD=1
    export GIT_DIR="${sacrificial}/.git"
    export GIT_WORK_TREE="${sacrificial}"
    # Config overrides as well as repository pointers: these apply to every
    # git invocation the child makes, fixture setup and wrapper alike.
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=user.name
    export GIT_CONFIG_VALUE_0=HOSTILE
    export GIT_CONFIG_KEY_1=core.excludesFile
    export GIT_CONFIG_VALUE_1="${sacrificial}/excludes"
    # An orphan pair the counter does not reach, and a counter value that is
    # neither a usable bound nor a decimal number.
    export GIT_CONFIG_KEY_7=core.hooksPath
    export GIT_CONFIG_VALUE_7="${sacrificial}/hooks"
    exec bash "${SUITE_PATH}"
  ) > "${WORKROOT}/child.log" 2>&1
  CHILD_RC=$?
  set -o errexit

  after_head="$(git -C "${sacrificial}" rev-parse HEAD)"
  after_name="$(git -C "${sacrificial}" config user.name)"
  after_index="$(git -C "${sacrificial}" diff --cached --name-only | sort | tr '\n' ' ')"

  child_passed(){ [[ "${CHILD_RC}" -eq 0 ]]; }
  head_unchanged(){ [[ "${before_head}" == "${after_head}" ]]; }
  config_unchanged(){ [[ "${before_name}" == "${after_name}" && "${after_name}" == "SENTINEL" ]]; }
  index_unchanged(){ [[ "${before_index}" == "${after_index}" ]]; }

  check "the suite still passes with GIT_DIR exported" child_passed
  check "sacrificial HEAD unchanged" head_unchanged
  check "sacrificial config unchanged" config_unchanged
  check "sacrificial index unchanged" index_unchanged
fi

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
