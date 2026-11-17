#!/bin/bash
# Behavior tests for the baremetalds-e2e-bgp-vip-verify step.
#
# Run locally with:
#   bash hack/tests/baremetalds-e2e-bgp-vip-verify-commands_test.sh
#   bash hack/tests/baremetalds-e2e-bgp-vip-verify-commands_test.sh --callers
#
# By default the step script runs unmodified against fake ssh and
# openshift-tests executables, covering how the bash checks and the origin
# suites combine into the step result. This mode needs only bash and coreutils
# and runs in the step-registry-shellcheck presubmit through
# hack/validate-registry-commands.sh.
#
# --callers instead walks the step registry and every ci-operator
# configuration that runs the step, directly or through a chain or workflow,
# prints the caller matrix and asserts that only callers testing a release
# whose openshift-tests predates the suites opt out of requiring them. It needs
# a full checkout and python3 with PyYAML.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
STEP_DIR="${REPO_ROOT}/ci-operator/step-registry/baremetalds/e2e/bgp-vip/verify"
COMMAND_SCRIPT="${STEP_DIR}/baremetalds-e2e-bgp-vip-verify-commands.sh"
REF_FILE="${STEP_DIR}/baremetalds-e2e-bgp-vip-verify-ref.yaml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

BGP_VIP=openshift/bgp-vip
BGP_VIP_DISRUPTIVE=openshift/bgp-vip/disruptive
OTHER_SUITE=openshift/conformance/parallel

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ref_default <name>: the double-quoted default of an env entry in the ref.
ref_default() {
  awk -v name="$1" '
    $1 == "-" && $2 == "name:" { in_entry = ($3 == name); next }
    in_entry && $1 == "default:" {
      value = $0
      if (!sub(/^[[:space:]]*default:[[:space:]]*"/, "", value) || !sub(/"[[:space:]]*$/, "", value)) {
        exit
      }
      print value
      found = 1
      exit
    }
    END { exit !found }
  ' "${REF_FILE}" || fail "no double-quoted default for $1 in ${REF_FILE}"
}

DEFAULT_SUITES=$(ref_default BGP_VIP_ORIGIN_SUITES)
DEFAULT_MONITORS=$(ref_default BGP_VIP_ORIGIN_DISABLED_MONITORS)
DEFAULT_REQUIRED=$(ref_default BGP_VIP_ORIGIN_SUITES_REQUIRED)
[[ "${DEFAULT_SUITES}" == "${BGP_VIP} ${BGP_VIP_DISRUPTIVE}" ]] || fail "unexpected BGP_VIP_ORIGIN_SUITES default '${DEFAULT_SUITES}'"
[[ -n "${DEFAULT_MONITORS}" ]] || fail "BGP_VIP_ORIGIN_DISABLED_MONITORS default is empty"
[[ "${DEFAULT_REQUIRED}" == "true" ]] || fail "BGP_VIP_ORIGIN_SUITES_REQUIRED must default to true, got '${DEFAULT_REQUIRED}'"

make_fixture() {
  local case_dir="$1"
  mkdir -p "${case_dir}/bin" "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/profile" "${case_dir}/home" "${case_dir}/state"
  touch "${case_dir}/state/calls"
  printf 'fixture-key\n' > "${case_dir}/profile/packet-ssh-key"
  cat > "${case_dir}/shared/packet-conf.sh" <<'EOF'
IP=192.0.2.10
PORT=22
SSHOPTS=(-o 'StrictHostKeyChecking=no' -i "${CLUSTER_PROFILE_DIR}/packet-ssh-key")
EOF
  printf 'export DS_IP_STACK=v4\n' > "${case_dir}/shared/ds-vars.conf"

  # The bash checks run on the hypervisor through ssh; keep the script they
  # receive and report the configured result.
  cat > "${case_dir}/bin/ssh" <<'EOF'
#!/bin/bash
cat > "${MOCK_STATE_DIR}/ssh-stdin"
printf 'ssh %s\n' "$*" >> "${MOCK_STATE_DIR}/calls"
exit "${MOCK_SSH_RC}"
EOF

  # Mirrors the default "openshift-tests list suites" output: one unindented
  # line per suite name followed by indented details.
  cat > "${case_dir}/bin/openshift-tests" <<'EOF'
#!/bin/bash
printf 'openshift-tests %s\n' "$*" >> "${MOCK_STATE_DIR}/calls"
case "${1:-} ${2:-}" in
  "list suites")
    if [[ "${MOCK_LIST_RC}" != 0 ]]; then
      echo "fixture: failed to load test extensions" >&2
      exit "${MOCK_LIST_RC}"
    fi
    printf 'Available test suites:\n\n'
    for suite in ${MOCK_SHIPPED_SUITES}; do
      printf '%s\n  Source: Internal\n  Description:\n    Fixture suite %s.\n\n' "${suite}" "${suite}"
    done
    ;;
  "run "*)
    for failing in ${MOCK_FAILING_SUITES}; do
      if [[ "${failing}" == "$2" ]]; then
        echo "fixture: suite $2 failed"
        exit 1
      fi
    done
    ;;
  *)
    echo "fixture: unexpected openshift-tests invocation: $*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "${case_dir}/bin/ssh" "${case_dir}/bin/openshift-tests"
}

# run_case <name> [VAR=value ...]: runs the step; leaves CASE_DIR and CASE_RC.
# VARs: SSH_RC, LIST_RC, SHIPPED, FAILING, SUITES, REQUIRED.
run_case() {
  local name="$1"; shift
  local SSH_RC=0 LIST_RC=0 SHIPPED="${OTHER_SUITE} ${BGP_VIP} ${BGP_VIP_DISRUPTIVE}" FAILING=""
  local SUITES="${DEFAULT_SUITES}" REQUIRED="${DEFAULT_REQUIRED}"
  local assignment
  for assignment in "$@"; do
    case "${assignment%%=*}" in
      SSH_RC|LIST_RC|SHIPPED|FAILING|SUITES|REQUIRED) local "${assignment}" ;;
      *) fail "unknown run_case variable ${assignment}" ;;
    esac
  done
  CASE_DIR="${TEST_ROOT}/${name}"
  make_fixture "${CASE_DIR}"
  CASE_RC=0
  (
    export SHARED_DIR="${CASE_DIR}/shared" ARTIFACT_DIR="${CASE_DIR}/artifacts"
    export CLUSTER_PROFILE_DIR="${CASE_DIR}/profile" HOME="${CASE_DIR}/home"
    export PATH="${CASE_DIR}/bin:${PATH}" MOCK_STATE_DIR="${CASE_DIR}/state"
    export MOCK_SSH_RC="${SSH_RC}" MOCK_LIST_RC="${LIST_RC}"
    export MOCK_SHIPPED_SUITES="${SHIPPED}" MOCK_FAILING_SUITES="${FAILING}"
    export BGP_VIP_ORIGIN_SUITES="${SUITES}" BGP_VIP_ORIGIN_SUITES_REQUIRED="${REQUIRED}"
    export BGP_VIP_ORIGIN_DISABLED_MONITORS="${DEFAULT_MONITORS}"
    bash "${COMMAND_SCRIPT}"
  ) > "${CASE_DIR}/output.log" 2>&1 || CASE_RC=$?
}

show_case() {
  echo "--- ${CASE_DIR}/output.log" >&2
  cat "${CASE_DIR}/output.log" >&2
  echo "--- ${CASE_DIR}/state/calls" >&2
  cat "${CASE_DIR}/state/calls" >&2
}

expect_rc() {
  [[ "${CASE_RC}" == "$1" ]] || { show_case; fail "${CASE_DIR##*/}: expected exit $1, got ${CASE_RC}"; }
}

expect_output() {
  grep -Fq -- "$1" "${CASE_DIR}/output.log" || { show_case; fail "${CASE_DIR##*/}: expected output '$1'"; }
}

expect_no_output() {
  if grep -Fq -- "$1" "${CASE_DIR}/output.log"; then show_case; fail "${CASE_DIR##*/}: unexpected output '$1'"; fi
}

# expect_runs [suite ...]: exactly these suites were run, in this order.
expect_runs() {
  local expected="" actual
  if [[ "$#" -ne 0 ]]; then expected=$(printf '%s\n' "$@"); fi
  actual=$(sed -n 's/^openshift-tests run \([^ ]*\) .*/\1/p' "${CASE_DIR}/state/calls")
  [[ "${actual}" == "${expected}" ]] || { show_case; fail "${CASE_DIR##*/}: expected suite runs [$*], got [$(tr '\n' ' ' <<<"${actual}")]"; }
}

expect_discovery_calls() {
  local actual
  actual=$(grep -c '^openshift-tests list suites$' "${CASE_DIR}/state/calls" || true)
  [[ "${actual}" == "$1" ]] || { show_case; fail "${CASE_DIR##*/}: expected $1 suite discovery call(s), got ${actual}"; }
}

# The bash checks still run first, once, with the full remote script.
expect_checks_ran() {
  local actual
  actual=$(grep -c '^ssh ' "${CASE_DIR}/state/calls" || true)
  [[ "${actual}" == 1 ]] || { show_case; fail "${CASE_DIR##*/}: expected the checks to run once over ssh, got ${actual}"; }
  [[ "$(sed -n 1p "${CASE_DIR}/state/calls")" == ssh\ * ]] || { show_case; fail "${CASE_DIR##*/}: the checks did not run first"; }
  local check
  for check in '[1/6]' '[2/6]' '[3/6]' '[4/6]' '[5/6]' '[6/6]' 'BGP VIP verification passed'; do
    grep -Fq -- "${check}" "${CASE_DIR}/state/ssh-stdin" || { show_case; fail "${CASE_DIR##*/}: remote checks script lacks '${check}'"; }
  done
}

PASSED=0
pass() {
  PASSED=$((PASSED + 1))
  echo "PASS: $1"
}

test_all_suites_present() {
  run_case all-present
  expect_rc 0
  expect_checks_ran
  expect_discovery_calls 1
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  local run_args
  run_args=$(grep "^openshift-tests run ${BGP_VIP} " "${CASE_DIR}/state/calls")
  local arg
  for arg in '--provider {"type":"baremetal"}' '"hypervisorIP":"192.0.2.10"' "\"privateKeyPath\":\"${CASE_DIR}/profile/packet-ssh-key\"" \
    "--disable-monitor ${DEFAULT_MONITORS}" "-o ${CASE_DIR}/artifacts/openshift_bgp-vip/e2e.log" "--junit-dir ${CASE_DIR}/artifacts/openshift_bgp-vip/junit"; do
    [[ "${run_args}" == *"${arg}"* ]] || { show_case; fail "all-present: run arguments lack '${arg}'"; }
  done
  expect_no_output "ERROR"
  pass "all suites present: checks and both suites run, step passes"
}

test_discovery_failure_required() {
  run_case discovery-failure LIST_RC=3
  expect_rc 1
  expect_checks_ran
  expect_output "openshift-tests list suites failed"
  expect_output "fixture: failed to load test extensions"
  grep -Fq "fixture: failed to load test extensions" "${CASE_DIR}/artifacts/openshift-tests-list-suites.log" \
    || fail "discovery-failure: stderr not kept in the artifacts"
  expect_output "openshift-tests suite discovery failed, so the BGP VIP origin suites could not be confirmed"
  # A failed discovery is not "nothing shipped": the suites still run and report.
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_no_output "skipping"
  pass "required: discovery failure fails the step; the suites still run"
}

test_all_suites_missing_required() {
  run_case all-missing SHIPPED="${OTHER_SUITE}"
  expect_rc 1
  expect_checks_ran
  expect_runs
  expect_output "ERROR: openshift-tests in this payload does not ship required suite ${BGP_VIP}"
  expect_output "ERROR: openshift-tests in this payload does not ship required suite ${BGP_VIP_DISRUPTIVE}"
  expect_output "Required BGP VIP origin suites missing from the payload's openshift-tests: ${BGP_VIP} ${BGP_VIP_DISRUPTIVE}"
  expect_no_output "skipping"
  pass "required: every suite missing fails the step"
}

test_empty_discovery_required() {
  run_case empty-discovery SHIPPED=""
  expect_rc 1
  expect_runs
  expect_output "Required BGP VIP origin suites missing from the payload's openshift-tests: ${BGP_VIP} ${BGP_VIP_DISRUPTIVE}"
  pass "required: discovery that succeeds but lists nothing fails the step"
}

test_one_suite_missing_required() {
  # Only the disruptive suite ships; its name extends the missing one, so this
  # also proves the match is on whole lines.
  run_case one-missing SHIPPED="${OTHER_SUITE} ${BGP_VIP_DISRUPTIVE}"
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP_DISRUPTIVE}"
  expect_output "ERROR: openshift-tests in this payload does not ship required suite ${BGP_VIP}"
  expect_output "Required BGP VIP origin suites missing from the payload's openshift-tests: ${BGP_VIP}"
  expect_no_output "does not ship required suite ${BGP_VIP_DISRUPTIVE}"
  expect_no_output "origin suites failed"
  pass "required: one suite missing fails the step; the other still runs"
}

test_suite_execution_failure() {
  run_case suite-failure FAILING="${BGP_VIP}"
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP origin suites failed: ${BGP_VIP}"
  expect_no_output "verification checks failed"
  pass "suite execution failure fails the step; the next suite still runs"
}

test_all_suites_fail() {
  run_case all-suites-fail FAILING="${BGP_VIP} ${BGP_VIP_DISRUPTIVE}"
  expect_rc 1
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP origin suites failed: ${BGP_VIP} ${BGP_VIP_DISRUPTIVE}"
  pass "every suite failure is reported"
}

test_checks_fail_suites_still_run() {
  run_case checks-fail SSH_RC=1
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP verification checks failed (exit 1)"
  expect_no_output "origin suites failed"
  pass "failed bash checks fail the step; both suites still run"
}

test_checks_and_suite_fail() {
  run_case checks-and-suite-fail SSH_RC=1 FAILING="${BGP_VIP_DISRUPTIVE}"
  expect_rc 1
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP verification checks failed (exit 1)"
  expect_output "BGP VIP origin suites failed: ${BGP_VIP_DISRUPTIVE}"
  pass "check and suite failures are reported independently"
}

test_checks_fail_and_suite_missing() {
  run_case checks-fail-suite-missing SSH_RC=1 SHIPPED="${BGP_VIP}"
  expect_rc 1
  expect_runs "${BGP_VIP}"
  expect_output "BGP VIP verification checks failed (exit 1)"
  expect_output "Required BGP VIP origin suites missing from the payload's openshift-tests: ${BGP_VIP_DISRUPTIVE}"
  pass "check failure and a missing required suite are reported independently"
}

test_legacy_opt_out_suites_missing() {
  run_case legacy-missing REQUIRED=false SHIPPED="${OTHER_SUITE}"
  expect_rc 0
  expect_checks_ran
  expect_runs
  expect_output "does not ship suite ${BGP_VIP} (added by openshift/origin#31893); skipping it (BGP_VIP_ORIGIN_SUITES_REQUIRED=false)"
  expect_output "does not ship suite ${BGP_VIP_DISRUPTIVE} (added by openshift/origin#31893); skipping it (BGP_VIP_ORIGIN_SUITES_REQUIRED=false)"
  expect_no_output "ERROR"
  pass "legacy opt-out: missing suites are skipped, step passes on the checks"
}

test_legacy_opt_out_discovery_failure() {
  # The opt-out only covers suites a working discovery does not list; a
  # failed discovery is still a failure.
  run_case legacy-discovery-failure REQUIRED=false LIST_RC=3
  expect_rc 1
  expect_checks_ran
  expect_runs
  expect_output "openshift-tests list suites failed"
  expect_output "suite discovery failed; not running ${BGP_VIP} (BGP_VIP_ORIGIN_SUITES_REQUIRED=false)"
  expect_output "suite discovery failed; not running ${BGP_VIP_DISRUPTIVE} (BGP_VIP_ORIGIN_SUITES_REQUIRED=false)"
  expect_output "openshift-tests suite discovery failed, so the BGP VIP origin suites could not be confirmed"
  pass "legacy opt-out: discovery failure still fails the step"
}

test_legacy_opt_out_runs_shipped_suites() {
  run_case legacy-present REQUIRED=false FAILING="${BGP_VIP_DISRUPTIVE}"
  expect_rc 1
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP origin suites failed: ${BGP_VIP_DISRUPTIVE}"
  pass "legacy opt-out: shipped suites still run and their failures count"
}

test_legacy_opt_out_keeps_check_failures() {
  run_case legacy-checks-fail REQUIRED=false SSH_RC=1 SHIPPED="${OTHER_SUITE}"
  expect_rc 1
  expect_runs
  expect_output "BGP VIP verification checks failed (exit 1)"
  pass "legacy opt-out: failed checks still fail the step"
}

test_invalid_required_value() {
  local value
  for value in False yes ""; do
    run_case "invalid-required-${value:-empty}" REQUIRED="${value}"
    expect_rc 1
    expect_output "BGP_VIP_ORIGIN_SUITES_REQUIRED must be \"true\" or \"false\", got \"${value}\""
    [[ ! -s "${CASE_DIR}/state/calls" ]] || { show_case; fail "invalid-required: nothing may run before the value is validated"; }
  done
  pass "an invalid BGP_VIP_ORIGIN_SUITES_REQUIRED fails before anything runs"
}

test_checks_only() {
  run_case checks-only SUITES=""
  expect_rc 0
  expect_checks_ran
  expect_discovery_calls 0
  expect_runs
  pass "BGP_VIP_ORIGIN_SUITES=\"\" still runs the checks only"
}

test_whitespace_only_suites() {
  # No suite requested, so a broken discovery must not even be consulted.
  run_case whitespace-only-suites SUITES=$' \t\n ' LIST_RC=3
  expect_rc 0
  expect_checks_ran
  expect_discovery_calls 0
  expect_runs
  pass "a whitespace-only BGP_VIP_ORIGIN_SUITES runs the checks only"
}

test_suite_list_parsing() {
  run_case suite-list-newlines SUITES=$'\n'"${BGP_VIP}"$'\n\t'"${BGP_VIP_DISRUPTIVE} "
  expect_rc 0
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  # A suite name is never glob-expanded against the working directory.
  run_case suite-list-glob SUITES='*'
  expect_rc 1
  expect_runs
  expect_output "Required BGP VIP origin suites missing from the payload's openshift-tests: *"
  pass "suites split on any whitespace and are never glob-expanded"
}

# Every ci-operator configuration that runs the step, directly or through a
# chain or workflow, must require the suites unless the release it tests (the
# "latest" release, which provides the tests image and its openshift-tests)
# predates them; those callers must opt out explicitly.
test_caller_matrix() {
  python3 -c 'import yaml' 2>/dev/null || fail "--callers needs python3 with PyYAML"
  [[ -d "${REPO_ROOT}/ci-operator/config" ]] || fail "--callers needs a full checkout with ci-operator/config"
  python3 - "${REPO_ROOT}" <<'EOF'
import os, sys, yaml

Loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
root = sys.argv[1]
TARGET = "baremetalds-e2e-bgp-vip-verify"
ENV = "BGP_VIP_ORIGIN_SUITES_REQUIRED"
FIRST_RELEASE_WITH_SUITES = (5, 1)  # openshift/origin#31893: main, release-5.1 and later

registry = os.path.join(root, "ci-operator/step-registry")
chains, workflows = {}, {}
for dirpath, _, files in os.walk(registry):
    for name in files:
        if name.endswith("-chain.yaml") or name.endswith("-workflow.yaml"):
            with open(os.path.join(dirpath, name)) as f:
                doc = yaml.load(f, Loader=Loader)
            if "chain" in doc:
                chains[doc["chain"]["as"]] = doc["chain"]
            else:
                workflows[doc["workflow"]["as"]] = doc["workflow"]

ref = yaml.safe_load(open(os.path.join(registry, "baremetalds/e2e/bgp-vip/verify", TARGET + "-ref.yaml")))["ref"]
default = next(e["default"] for e in ref["env"] if e["name"] == ENV)

def runs_target(items, seen=()):
    for item in items or []:
        if item.get("ref") == TARGET:
            return True
        chain = item.get("chain")
        if chain and chain not in seen and runs_target(chains[chain].get("steps"), seen + (chain,)):
            return True
    return False

names = {TARGET}
names |= {n for n, c in chains.items() if runs_target(c.get("steps"))}
names |= {n for n, w in workflows.items()
          if any(runs_target(w.get("steps", {}).get(p)) for p in ("pre", "test", "post"))}

def release_line(cfg):
    latest = (cfg.get("releases") or {}).get("latest") or {}
    version = (latest.get("integration") or {}).get("name") or (latest.get("candidate") or {}).get("version") \
        or (latest.get("release") or {}).get("version")
    if not version:
        return None
    return tuple(int(x) for x in str(version).split(".")[:2])

rows, errors = [], []
config_root = os.path.join(root, "ci-operator/config")
for dirpath, _, files in os.walk(config_root):
    for name in sorted(files):
        if not name.endswith(".yaml"):
            continue
        path = os.path.join(dirpath, name)
        with open(path) as f:
            text = f.read()
        if not any(n in text for n in names):
            continue
        cfg = yaml.load(text, Loader=Loader)
        for test in cfg.get("tests") or []:
            steps = test.get("steps") or {}
            workflow = workflows.get(steps.get("workflow"), {}).get("steps", {})
            phases = [steps[p] if p in steps else workflow.get(p) for p in ("pre", "test", "post")]
            if not any(runs_target(p) for p in phases):
                continue
            env = dict(workflow.get("env") or {})
            env.update(steps.get("env") or {})
            effective = str(env.get(ENV, default))
            line = release_line(cfg)
            rel = os.path.relpath(path, root)
            if line is None:
                errors.append(f"{rel} {test['as']}: cannot tell which release it tests")
                continue
            want = "true" if line >= FIRST_RELEASE_WITH_SUITES else "false"
            rows.append((rel, test["as"], steps.get("workflow", "-"), "%d.%d" % line, effective,
                         "explicit" if ENV in env else "default"))
            if effective != want:
                errors.append(f"{rel} {test['as']}: {ENV}={effective}, want {want} for release {line[0]}.{line[1]}")

for row in rows:
    print("  %s | %s | %s | release %s | %s=%s (%s)" % (row[0], row[1], row[2], row[3], ENV, row[4], row[5]))
required = [r for r in rows if r[4] == "true"]
opted_out = [r for r in rows if r[4] == "false"]
print(f"  callers: {len(rows)} ({len(required)} require the suites, {len(opted_out)} opt out)")
if not required or not opted_out:
    errors.append("expected both requiring and opted-out callers; the inventory looks incomplete")
for e in errors:
    print("ERROR: " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
EOF
  pass "caller matrix: only callers testing releases older than 5.1 opt out"
}

if [[ "${1:-}" == "--callers" ]]; then
  test_caller_matrix
  exit
fi
[[ "$#" -eq 0 ]] || fail "usage: $0 [--callers]"

test_all_suites_present
test_discovery_failure_required
test_all_suites_missing_required
test_empty_discovery_required
test_one_suite_missing_required
test_suite_execution_failure
test_all_suites_fail
test_checks_fail_suites_still_run
test_checks_and_suite_fail
test_checks_fail_and_suite_missing
test_legacy_opt_out_suites_missing
test_legacy_opt_out_discovery_failure
test_legacy_opt_out_runs_shipped_suites
test_legacy_opt_out_keeps_check_failures
test_invalid_required_value
test_checks_only
test_whitespace_only_suites
test_suite_list_parsing

echo "PASS: baremetalds-e2e-bgp-vip-verify tests (${PASSED} passed)"
