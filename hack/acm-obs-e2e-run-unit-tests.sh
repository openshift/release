#!/bin/bash
set -euo pipefail

# Required targeted check for changes to acm-obs-e2e-run-commands.sh:
#   hack/acm-obs-e2e-run-unit-tests.sh
# Baseline reports are sanitized output from the isolated Ginkgo 2.27.2 suite
# documented under hack/testdata/acm-obs-e2e-run/ginkgo-2.27.2. Corruption
# scenarios mutate copies of those genuine reports inside each private tree.

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scriptDir
readonly commandScript="${scriptDir}/../ci-operator/step-registry/acm/obs/e2e-run/acm-obs-e2e-run-commands.sh"
readonly reportFixtures="${scriptDir}/testdata/acm-obs-e2e-run/ginkgo-2.27.2"
testRoot="$(mktemp -d /tmp/acm-obs-e2e-unit.XXXXXX)"
readonly testRoot

cleanup_harness() {
    local record root
    while IFS= read -r record; do
        [[ -s "${record}" ]] || continue
        root="$(<"${record}")"
        case "${root}" in
            /tmp/acm-obs-e2e.*) /bin/rm -rf "${root}" ;;
        esac
    done < <(find "${testRoot}" -type f -name work-root -print 2>/dev/null)
    /bin/rm -rf "${testRoot}"
}
trap cleanup_harness EXIT

passCount=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

verify_genuine_fixtures() {
    python3 - "${reportFixtures}" <<'PY'
import json
import pathlib
import re
import xml.etree.ElementTree as ET
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "pass": ("passed", True),
    "body-assertion": ("failed", False),
    "before-each": ("failed", False),
    "after-each": ("failed", False),
    "defer-cleanup": ("failed", False),
    "timeout-nested": ("timedout", False),
    "panic": ("panicked", False),
}
for scenario, (state, succeeded) in expected.items():
    report = json.loads((root / scenario / "report.json").read_text())[0]
    assert report["SuiteSucceeded"] is succeeded, scenario
    assert report["SpecReports"][0]["State"] == state, scenario
    assert ET.parse(root / scenario / "report.xml").getroot().tag == "testsuites"

assert json.loads((root / "before-each" / "report.json").read_text())[0]["SpecReports"][0]["Failure"]["FailureNodeType"] == "BeforeEach"
for scenario, node_type in (("after-each", "AfterEach"), ("defer-cleanup", "DeferCleanup (Each)")):
    additional = json.loads((root / scenario / "report.json").read_text())[0]["SpecReports"][0]["AdditionalFailures"]
    assert additional[0]["Failure"]["FailureNodeType"] == node_type
timeout_failure = json.loads((root / "timeout-nested" / "report.json").read_text())[0]["SpecReports"][0]["Failure"]
assert timeout_failure["AdditionalFailure"]["State"] == "failed"
panic_failure = json.loads((root / "panic" / "report.json").read_text())[0]["SpecReports"][0]["Failure"]
assert panic_failure["ForwardedPanic"] == "fixture panic"

skip_report = json.loads((root / "skipped-pending" / "report.json").read_text())[0]
assert [spec["State"] for spec in skip_report["SpecReports"]] == ["pending", "skipped"]
suite = ET.parse(root / "skipped-pending" / "report.xml").getroot().find("testsuite")
assert suite is not None
assert suite.get("disabled") == "1" and suite.get("skipped") == "1"

for report_path in root.glob("*/report.*"):
    content = report_path.read_text()
    assert "/workspace/" not in content, report_path
    assert "/home/" not in content, report_path
    assert not re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", content), report_path
    assert "kubeconfig" not in content.lower(), report_path
PY
}

verify_fixture_timing_provenance() {
    python3 - "${reportFixtures}" <<'PY'
import json
import pathlib
import xml.etree.ElementTree as ET
import sys

root = pathlib.Path(sys.argv[1]) / "timeout-nested"
report = json.loads((root / "report.json").read_text())[0]
spec = report["SpecReports"][0]
assert report["StartTime"] == report["EndTime"] == "2026-10-09T00:00:00Z"
assert spec["StartTime"] == spec["EndTime"] == "2026-10-09T00:00:00Z"
assert report["RunTime"] == 151957087
assert spec["RunTime"] == 151375957

testsuites = ET.parse(root / "report.xml").getroot()
testsuite = testsuites.find("testsuite")
testcase = testsuite.find("testcase")
assert testsuites.get("time") == "0.001"
assert testsuite.get("time") == "0.001"
assert testcase.get("time") == "0.001"
reporter_text = testcase.findtext("system-err", default="")
assert "@ 10/09/26 23:01:19.829" in reporter_text
assert "(151ms)" in reporter_text
PY
    echo "PASS: fixture timing provenance"
}

make_fixture() {
    local fixture=$1
    local scenario=$2
    mkdir -p "${fixture}/source/tests/pkg/tests" "${fixture}/source/examples" \
        "${fixture}/bin" "${fixture}/shared" "${fixture}/artifacts"
    printf 'module example.test/observability\n\ngo 1.25.0\n\nrequire (\n\tgithub.com/onsi/ginkgo/v2 v2.27.2\n)\n' \
        > "${fixture}/source/go.mod"
    printf 'package tests\n// ../../../examples/fixture.txt\n' > "${fixture}/source/tests/pkg/tests/suite_test.go"
    printf 'copied source fixture\n' > "${fixture}/source/examples/fixture.txt"
    printf 'synthetic hub kubeconfig\n' > "${fixture}/shared/kubeconfig"
    if [[ "${scenario}" != 'absent-managed' ]]; then
        printf 'synthetic managed kubeconfig\n' > "${fixture}/shared/managed-cluster-kubeconfig"
    fi
    printf '{}\n' > "${fixture}/shared/acm-obs-options.json"

    cat > "${fixture}/bin/mktemp" <<'MKTEMP'
#!/bin/bash
set -euo pipefail
root="$(/usr/bin/mktemp "$@")"
printf '%s\n' "${root}" > "${WORK_ROOT_RECORD}"
printf '%s\n' "${root}"
MKTEMP

    cat > "${fixture}/bin/mkdir" <<'MKDIR'
#!/bin/bash
set -euo pipefail
if [[ "${SCENARIO}" == 'early-init-failure' ]]; then
    for arg in "$@"; do
        if [[ "${arg}" == /tmp/acm-obs-e2e.*/reports ]]; then
            exit 58
        fi
    done
fi
exec /bin/mkdir "$@"
MKDIR

    cat > "${fixture}/bin/subreaper" <<'SUBREAPER'
#!/usr/bin/env python3
import ctypes
import os
import subprocess
import sys

PR_SET_CHILD_SUBREAPER = 36
if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER) failed")

child = subprocess.Popen(sys.argv[1:])
returncode = child.wait()
# Reap hard-killed descendants that were orphaned when their cooperative
# parent exited on TERM. If any descendant incorrectly remains alive, this
# wait stays blocked until the outer harness timeout fails the case.
while True:
    try:
        os.wait()
    except ChildProcessError:
        break
raise SystemExit(returncode if returncode >= 0 else 128 - returncode)
SUBREAPER

    cat > "${fixture}/bin/rm" <<'RM'
#!/bin/bash
set -euo pipefail
if [[ "${SCENARIO}" == 'cleanup-propagation-prior-failure' || \
      "${SCENARIO}" == 'cleanup-removal-prior-failure' ]]; then
    if [[ "${1:-}" == '-f' && $# -eq 2 && "${2}" == /tmp/acm-obs-e2e.*/reports/ginkgo-report.json ]]; then
        exit 42
    fi
fi
if [[ "${SCENARIO}" == 'cleanup-removal-prior-failure' && "${1:-}" == '-rf' && $# -eq 2 && "${2}" == /tmp/acm-obs-e2e.* ]]; then
    printf '%s\n' "${2}" > "${WORK_ROOT_RECORD}"
    exit 55
fi
exec /bin/rm "$@"
RM

    cat > "${fixture}/bin/cp" <<'CP'
#!/bin/bash
set -euo pipefail
if [[ ( "${SCENARIO}" == 'cleanup-propagation-failure' || \
        "${SCENARIO}" == 'cleanup-propagation-prior-failure' ) && \
      "${*: -1}" == "${SHARED_DIR}/junit/" ]]; then
    exit 56
fi
exec /bin/cp "$@"
CP

    cat > "${fixture}/bin/go" <<'GO'
#!/bin/bash
set -euo pipefail

die() {
    echo "fake go contract failure: $*" >&2
    exit 96
}

if [[ "$1 $2" == "env GOVERSION" ]]; then
    if [[ "${SCENARIO}" == 'go-version-mismatch' ]]; then
        echo 'go1.24.0'
    else
        echo 'go1.25.0'
    fi
    exit 0
fi
if [[ "$1" == "build" ]]; then
    [[ "${PWD}" == "${REPO_DIR}" ]] || die "build cwd"
    [[ "${GOTOOLCHAIN}" == 'go1.25.0+auto' ]] || die "GOTOOLCHAIN"
    [[ "${GOFLAGS}" == '-mod=readonly' ]] || die "GOFLAGS"
    private_root=${HOME%/go/home}
    for variable in HOME GOPATH GOCACHE GOMODCACHE; do
        value=${!variable}
        [[ "${value}" == "${private_root}"/* && -d "${value}" && -w "${value}" ]] || \
            die "${variable} private writable path"
    done
    if [[ "${SCENARIO}" == 'compile-failure' ]]; then
        exit 42
    fi
    if [[ "${SCENARIO}" == 'build-timeout' ]]; then
        on_term() {
            printf 'TERM\n' >> "${BUILD_SIGNAL_MARKER}"
            exit 0
        }
        trap on_term TERM
        bash -c 'trap "" TERM; while :; do sleep 1; done' &
        child=$!
        printf '%s\n' "${child}" > "${BUILD_CHILD_PID_RECORD}"
        wait "${child}" || true
    fi
    output=
    while (($#)); do
        if [[ "$1" == '-o' ]]; then
            output=$2
            break
        fi
        shift
    done
    [[ -n "${output}" && "${output}" == "${private_root}"/* ]] || die "private build output"
    case "${output}" in
        "${ARTIFACT_DIR}"/*|"${SHARED_DIR}"/*) die "published build output" ;;
    esac
    cp "${FAKE_GINKGO}" "${output}"
    chmod +x "${output}"
    exit 0
fi
echo "unexpected fake go invocation: $*" >&2
exit 2
GO

    cat > "${fixture}/bin/ginkgo" <<'GINKGO'
#!/bin/bash
set -euo pipefail

die() {
    echo "fake ginkgo contract failure: $*" >&2
    exit 97
}

has_arg() {
    local expected=$1
    shift
    local arg
    for arg in "$@"; do
        [[ "${arg}" == "${expected}" ]] && return 0
    done
    return 1
}

if [[ "${1:-}" == 'version' ]]; then
    if [[ "${SCENARIO}" == 'ginkgo-version-mismatch' ]]; then
        echo 'Ginkgo Version 2.17.1'
    else
        echo 'Ginkgo Version 2.27.2'
    fi
    exit 0
fi
if [[ "${1:-}" == 'build' ]]; then
    [[ "${PWD}" == "${SUITE_DIR}" ]] || die "build cwd"
    [[ $# -eq 2 && "${2}" == '.' ]] || die "build argv"
    printf '#!/bin/sh\nexit 0\n' > tests.test
    chmod +x tests.test
    exit 0
fi

[[ "${PWD}" == "${SUITE_DIR}" ]] || die "test cwd"
[[ "$(<../../../examples/fixture.txt)" == 'copied source fixture' ]] || die "nested copied fixture"
[[ "${KUBECONFIG}" != "${EXPECTED_HUB_KUBECONFIG}" ]] || die "hub kubeconfig was not copied"
cmp -s "${KUBECONFIG}" "${EXPECTED_HUB_KUBECONFIG}" || die "hub kubeconfig content"
if [[ "${SCENARIO}" == 'absent-managed' ]]; then
    [[ ! -v IMPORT_KUBECONFIG ]] || die "stale managed kubeconfig survived"
else
    [[ "${IMPORT_KUBECONFIG}" != "${EXPECTED_MANAGED_KUBECONFIG}" ]] || die "managed kubeconfig was not copied"
    cmp -s "${IMPORT_KUBECONFIG}" "${EXPECTED_MANAGED_KUBECONFIG}" || die "managed kubeconfig content"
fi
[[ "${OPTIONS}" == "${EXPECTED_OPTIONS}" ]] || die "options path"
[[ "${SKIP_INSTALL_STEP}" == 'true' ]] || die "install lifecycle"
[[ "${SKIP_UNINSTALL_STEP}" == 'true' ]] || die "uninstall lifecycle"
[[ "${IS_CANARY_ENV}" == 'true' ]] || die "canary env"
has_arg '--focus=focus' "$@" || die "focus argv"
has_arg '--skip=skip' "$@" || die "skip argv"
has_arg '--timeout=10s' "$@" || die "suite timeout argv"
has_arg '-nodes=1' "$@" || die "serial argv"
has_arg './tests.test' "$@" || die "test binary argv"
[[ "${*: -2}" == '-- -v=3' ]] || die "test passthrough argv"

output_dir=
junit_name=
json_name=
for arg in "$@"; do
    case "${arg}" in
        --output-dir=*) output_dir=${arg#*=} ;;
        --junit-report=*) junit_name=${arg#*=} ;;
        --json-report=*) json_name=${arg#*=} ;;
    esac
done
[[ -n "${output_dir}" && -n "${junit_name}" && -n "${json_name}" ]] || die "report argv"
case "${output_dir}" in
    "${ARTIFACT_DIR}"/*|"${SHARED_DIR}"/*) die "private report directory is published" ;;
esac
printf '%s\n' "${output_dir}/${json_name}" > "${JSON_PATH_RECORD}"

# The suite's hard-coded report must remain a duplicate that the wrapper removes.
printf '<testsuite name="duplicate"><testcase name="[It] duplicate" status="passed"/></testsuite>\n' > results.xml

fixture=pass
case "${SCENARIO}" in
    assertion-failure|assertion-panicked-message|signal-timeout|suite-true-with-failure|additional-false-*|forwarded-*|nested-valid-fatal|aborted|xml-failure-*|passed-with-failure) fixture=body-assertion ;;
    before-each-failure) fixture=before-each ;;
    after-each-additional) fixture=after-each ;;
    defer-cleanup-additional|cleanup-panic|nested-additional-invalid) fixture=defer-cleanup ;;
    panic|runner-error|xml-error-*) fixture=panic ;;
    timedout) fixture=timeout-nested ;;
    skipped-pending|skipped-*) fixture=skipped-pending ;;
esac
cp "${REPORT_FIXTURES}/${fixture}/report.xml" "${output_dir}/${junit_name}"
cp "${REPORT_FIXTURES}/${fixture}/report.json" "${output_dir}/${json_name}"

python3 - "${SCENARIO}" "${output_dir}/${junit_name}" "${output_dir}/${json_name}" "${REPORT_FIXTURES}" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

scenario, junit_path, json_path, fixtures = sys.argv[1:]

if scenario == "missing-junit" or scenario == "missing-junit-stale":
    import os
    os.remove(junit_path)
    raise SystemExit
if scenario == "missing-json":
    import os
    os.remove(json_path)
    raise SystemExit
if scenario == "malformed-junit":
    open(junit_path, "w", encoding="utf-8").write("<testsuites")
    raise SystemExit
if scenario == "malformed-json":
    open(json_path, "w", encoding="utf-8").write("[")
    raise SystemExit

reports = json.load(open(json_path, encoding="utf-8"))
report = reports[0]
spec = report["SpecReports"][0]
failure = spec.get("Failure")
tree = ET.parse(junit_path)
case = tree.getroot().find(".//testcase")

if scenario == "assertion-panicked-message":
    failure["Message"] = "ordinary assertion text says panicked but is not a panic"
elif scenario == "inconsistent-report":
    spec["State"] = "failed"
    spec["Failure"] = json.load(open(f"{fixtures}/body-assertion/report.json", encoding="utf-8"))[0]["SpecReports"][0]["Failure"]
    report["SuiteSucceeded"] = False
elif scenario == "zero-executed":
    report["SpecReports"] = []
    suite = tree.getroot().find("testsuite")
    suite.remove(case)
elif scenario == "runner-error":
    spec["State"] = "interrupted"
    case.set("status", "interrupted")
    case.find("error").set("type", "interrupted")
elif scenario == "aborted":
    spec["State"] = "aborted"
    case.set("status", "aborted")
    case.find("failure").set("type", "aborted")
elif scenario == "cleanup-panic":
    item = spec["AdditionalFailures"][0]
    item["State"] = "panicked"
    item["Failure"]["ForwardedPanic"] = "fixture cleanup panic"
elif scenario == "suite-missing-success":
    del report["SuiteSucceeded"]
elif scenario == "suite-nonboolean-success":
    report["SuiteSucceeded"] = 0
elif scenario == "suite-false-with-pass":
    report["SuiteSucceeded"] = False
elif scenario == "suite-true-with-failure":
    report["SuiteSucceeded"] = True
elif scenario == "special-suite-reason":
    report["SuiteSucceeded"] = False
    report["SpecialSuiteFailureReasons"] = ["fixture special reason"]
elif scenario == "passed-with-failure":
    spec["State"] = "passed"
    report["SuiteSucceeded"] = True
    case.set("status", "passed")
    case.remove(case.find("failure"))
elif scenario == "xml-failure-skipped":
    ET.SubElement(case, "skipped", {"message": "conflict"})
elif scenario == "xml-error-skipped":
    ET.SubElement(case, "skipped", {"message": "conflict"})
elif scenario == "xml-failure-wrong-type":
    case.find("failure").set("type", "timedout")
elif scenario == "xml-error-wrong-type":
    case.find("error").set("type", "interrupted")
elif scenario.startswith("additional-false-"):
    values = {"object": {}, "array": [], "zero": 0, "string": ""}
    failure["AdditionalFailure"] = values[scenario.removeprefix("additional-false-")]
elif scenario == "forwarded-empty":
    failure["ForwardedPanic"] = ""
elif scenario == "forwarded-zero":
    failure["ForwardedPanic"] = 0
elif scenario == "nested-additional-invalid":
    spec["AdditionalFailures"][0]["Failure"]["AdditionalFailure"] = {}
elif scenario == "nested-valid-fatal":
    nested = json.load(open(f"{fixtures}/timeout-nested/report.json", encoding="utf-8"))[0]["SpecReports"][0]["Failure"]["AdditionalFailure"]
    failure["AdditionalFailure"] = nested
elif scenario.startswith("skipped-") and scenario != "skipped-pending":
    specs = report["SpecReports"]
    specs[0]["State"] = "passed"
    cases = tree.getroot().findall(".//testcase")
    cases[0].set("status", "passed")
    cases[0].remove(cases[0].find("skipped"))
    skipped_failure = specs[1]["Failure"]
    if scenario == "skipped-forwarded-empty":
        skipped_failure["ForwardedPanic"] = ""
    elif scenario == "skipped-forwarded-zero":
        skipped_failure["ForwardedPanic"] = 0
    elif scenario == "skipped-forwarded-valid":
        skipped_failure["ForwardedPanic"] = "unexpected skip panic"
    elif scenario == "skipped-additional-empty":
        skipped_failure["AdditionalFailure"] = {}
    elif scenario == "skipped-additional-zero":
        skipped_failure["AdditionalFailure"] = 0
    elif scenario == "skipped-additional-nested":
        nested = json.load(open(f"{fixtures}/timeout-nested/report.json", encoding="utf-8"))[0]["SpecReports"][0]["Failure"]["AdditionalFailure"]
        nested["Failure"]["AdditionalFailure"] = {}
        skipped_failure["AdditionalFailure"] = nested
    elif scenario == "skipped-additional-valid":
        skipped_failure["AdditionalFailure"] = json.load(open(f"{fixtures}/timeout-nested/report.json", encoding="utf-8"))[0]["SpecReports"][0]["Failure"]["AdditionalFailure"]
    else:
        raise AssertionError(f"unhandled skipped scenario {scenario}")

with open(json_path, "w", encoding="utf-8") as stream:
    json.dump(reports, stream)
tree.write(junit_path, encoding="utf-8", xml_declaration=True)
PY

if [[ "${SCENARIO}" == 'signal-timeout' ]]; then
    on_term() {
        printf 'TERM\n' >> "${SIGNAL_MARKER}"
        exit 0
    }
    trap on_term TERM
    bash -c 'trap "" TERM; while :; do sleep 1; done' &
    child=$!
    printf '%s\n' "${child}" > "${CHILD_PID_RECORD}"
    wait "${child}" || true
fi

case "${fixture}" in
    pass|skipped-pending) exit 0 ;;
    *) exit 1 ;;
esac
GINKGO
    chmod +x "${fixture}/bin/mktemp" "${fixture}/bin/mkdir" "${fixture}/bin/subreaper" \
        "${fixture}/bin/rm" "${fixture}/bin/cp" \
        "${fixture}/bin/go" "${fixture}/bin/ginkgo"
}

assert_not_live() {
    local scenario=$1
    local pid_file=$2
    [[ -s "${pid_file}" ]] || fail "${scenario}: hanging child was not started"
    local child_pid state
    child_pid="$(<"${pid_file}")"
    for _ in {1..20}; do
        kill -0 "${child_pid}" 2>/dev/null || return 0
        state="$(ps -o stat= -p "${child_pid}" 2>/dev/null || true)"
        sleep 0.1
    done
    fail "${scenario}: hanging child ${child_pid} survived timeout cleanup (state=${state})"
}

run_case() {
    local scenario=$1
    local expected_rc=$2
    local expected_message=$3
    local classification=$4
    local canonical_mode=$5
    local map_tests=${6:-true}
    local fixture="${testRoot}/${scenario}"
    local wall_timeout='15s'
    local wall_kill_after='2s'
    local build_timeout='30s'
    local build_kill_after='2s'
    local started elapsed
    make_fixture "${fixture}" "${scenario}"

    if [[ "${scenario}" == 'signal-timeout' ]]; then
        wall_timeout='1s'
        wall_kill_after='1s'
    elif [[ "${scenario}" == 'build-timeout' ]]; then
        build_timeout='1s'
        build_kill_after='1s'
    fi

    if [[ "${scenario}" == 'missing-junit-stale' ]]; then
        mkdir -p "${fixture}/artifacts/obs-results" "${fixture}/shared/junit"
        printf '<testsuite name="stale"><testcase name="[It] stale" status="passed"/></testsuite>\n' \
            > "${fixture}/artifacts/obs-results/cli-results.xml"
        cp "${fixture}/artifacts/obs-results/cli-results.xml" \
            "${fixture}/artifacts/junit_acm-observability.xml"
        cp "${fixture}/artifacts/obs-results/cli-results.xml" \
            "${fixture}/shared/junit/junit_acm-observability.xml"
    fi

    started=${SECONDS}
    set +e
    PATH="${fixture}/bin:${PATH}" \
    IMPORT_KUBECONFIG="${fixture}/stale-import-kubeconfig" \
    SCENARIO="${scenario}" \
    FAKE_GINKGO="${fixture}/bin/ginkgo" \
    REPORT_FIXTURES="${reportFixtures}" \
    EXPECTED_HUB_KUBECONFIG="${fixture}/shared/kubeconfig" \
    EXPECTED_MANAGED_KUBECONFIG="${fixture}/shared/managed-cluster-kubeconfig" \
    EXPECTED_OPTIONS="${fixture}/shared/acm-obs-options.json" \
    JSON_PATH_RECORD="${fixture}/json-path" \
    SIGNAL_MARKER="${fixture}/signal-marker" \
    CHILD_PID_RECORD="${fixture}/child-pid" \
    BUILD_SIGNAL_MARKER="${fixture}/build-signal-marker" \
    BUILD_CHILD_PID_RECORD="${fixture}/build-child-pid" \
    WORK_ROOT_RECORD="${fixture}/work-root" \
    ACM_OBS_SOURCE_DIR="${fixture}/source" \
    ACM_OBS_BUILD_TIMEOUT="${build_timeout}" \
    ACM_OBS_BUILD_KILL_AFTER="${build_kill_after}" \
    ACM_OBS_SUITE_TIMEOUT='10s' \
    ACM_OBS_WALL_TIMEOUT="${wall_timeout}" \
    ACM_OBS_WALL_KILL_AFTER="${wall_kill_after}" \
    ARTIFACT_DIR="${fixture}/artifacts" \
    SHARED_DIR="${fixture}/shared" \
    MAP_TESTS="${map_tests}" \
    DR__RP__CR_COMP_NAME='component' \
    GINKGO_FOCUS='focus' \
    GINKGO_SKIP='skip' \
        timeout --signal=KILL 12s "${fixture}/bin/subreaper" \
            bash "${commandScript}" > "${fixture}/output.log" 2>&1
    rc=$?
    set -e
    elapsed=$((SECONDS - started))

    if ((rc != expected_rc)); then
        sed -n '1,260p' "${fixture}/output.log" >&2
        fail "${scenario}: expected rc ${expected_rc}, got ${rc}"
    fi
    if [[ -n "${expected_message}" ]] && ! grep -Fq -- "${expected_message}" "${fixture}/output.log"; then
        sed -n '1,260p' "${fixture}/output.log" >&2
        fail "${scenario}: missing expected diagnostic: ${expected_message}"
    fi
    if [[ "${scenario}" == 'signal-timeout' || "${scenario}" == 'build-timeout' ]]; then
        ((elapsed <= 8)) || fail "${scenario}: timeout cleanup exceeded bound (${elapsed}s)"
    fi

    if [[ "${classification}" == 'yes' && ! -s "${fixture}/json-path" ]]; then
        fail "${scenario}: classification scenario did not record its private JSON path"
    fi
    [[ -s "${fixture}/work-root" ]] || fail "${scenario}: private work root was not recorded"
    local work_root
    work_root="$(<"${fixture}/work-root")"
    case "${work_root}" in
        /tmp/acm-obs-e2e.*) ;;
        *) fail "${scenario}: invalid private work root record ${work_root}" ;;
    esac
    if [[ -f "${fixture}/json-path" ]]; then
        local json_path
        json_path="$(<"${fixture}/json-path")"
        [[ "$(dirname "$(dirname "${json_path}")")" == "${work_root}" ]] || \
            fail "${scenario}: JSON path does not belong to recorded private root"
        case "${json_path}" in
            "${fixture}/artifacts"/*|"${fixture}/shared"/*)
                fail "${scenario}: private JSON used a published path"
                ;;
        esac
    fi
    if [[ "${scenario}" == 'cleanup-removal-prior-failure' ]]; then
        [[ -d "${work_root}" ]] || \
            fail "${scenario}: forced rm failure did not leave the accurately reported private tree"
        /bin/rm -rf "${work_root}"
    else
        [[ ! -e "${work_root}" ]] || fail "${scenario}: private work root survived cleanup"
    fi

    if find "${fixture}/artifacts" "${fixture}/shared" -type f -name 'ginkgo-report.json' -print -quit | grep -q .; then
        fail "${scenario}: native Ginkgo JSON was recursively published"
    fi
    if find "${fixture}/artifacts" "${fixture}/shared" -type f -name 'results.xml' -print -quit | grep -q .; then
        fail "${scenario}: suite cwd results.xml was propagated"
    fi

    local canonical="${fixture}/artifacts/junit_acm-observability.xml"
    local shared="${fixture}/shared/junit/junit_acm-observability.xml"
    local diagnostic="${fixture}/artifacts/obs-results/cli-results.xml"
    case "${canonical_mode}" in
        absent)
            [[ ! -e "${canonical}" && ! -e "${shared}" ]] || \
                fail "${scenario}: unexpected canonical JUnit survived"
            ;;
        propagated|local-only)
            [[ -f "${canonical}" && -f "${diagnostic}" ]] || \
                fail "${scenario}: canonical or nonharvested diagnostic JUnit is missing"
            local artifact_count shared_count
            artifact_count="$(find "${fixture}/artifacts" -type f -name 'junit*.xml' | wc -l)"
            [[ "${artifact_count}" == 1 ]] || fail "${scenario}: expected exactly one artifact harvestable JUnit"
            if [[ "${canonical_mode}" == 'propagated' ]]; then
                [[ -f "${shared}" ]] || fail "${scenario}: shared canonical JUnit is missing"
                shared_count="$(find "${fixture}/shared" -type f -name 'junit*.xml' | wc -l)"
                [[ "${shared_count}" == 1 ]] || fail "${scenario}: expected exactly one shared harvestable JUnit"
                cmp -s "${canonical}" "${shared}" || fail "${scenario}: canonical/shared JUnit bytes differ"
            else
                [[ ! -e "${shared}" ]] || fail "${scenario}: failed propagation unexpectedly published JUnit"
            fi
            local expected_suite='component--ACM Observability Classifier Fixture Suite'
            [[ "${map_tests}" == 'false' ]] && expected_suite='ACM Observability Classifier Fixture Suite'
            python3 - "${canonical}" "${expected_suite}" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.tag == "testsuites"
suites = list(root.iter("testsuite"))
assert len(suites) == 1
assert suites[0].get("name") == sys.argv[2]
PY
            ;;
        *) fail "${scenario}: unknown canonical mode ${canonical_mode}" ;;
    esac

    [[ ! -e "${fixture}/source/tests/pkg/tests/tests.test" ]] || \
        fail "${scenario}: build modified the image source tree"

    if [[ "${scenario}" == 'missing-junit-stale' ]]; then
        [[ ! -e "${diagnostic}" ]] || fail "${scenario}: stale diagnostic JUnit survived"
    elif [[ "${scenario}" != 'compile-failure' && "${scenario}" != 'go-version-mismatch' && \
            "${scenario}" != 'ginkgo-version-mismatch' && "${scenario}" != 'build-timeout' && \
            "${scenario}" != 'early-init-failure' && "${scenario}" != 'missing-junit' && \
            "${scenario}" != 'missing-json' ]]; then
        [[ -f "${diagnostic}" ]] || fail "${scenario}: nonharvested diagnostic JUnit is missing"
    fi

    if [[ "${scenario}" == 'signal-timeout' ]]; then
        [[ -s "${fixture}/signal-marker" ]] || fail "${scenario}: TERM was not observed"
        assert_not_live "${scenario}" "${fixture}/child-pid"
    elif [[ "${scenario}" == 'build-timeout' ]]; then
        [[ -s "${fixture}/build-signal-marker" ]] || fail "${scenario}: build TERM was not observed"
        assert_not_live "${scenario}" "${fixture}/build-child-pid"
    fi

    passCount=$((passCount + 1))
    echo "PASS: ${scenario} (rc=${rc}, elapsed=${elapsed}s)"
}

if [[ "${1:-}" == '--verify-fixture-provenance' ]]; then
    verify_fixture_timing_provenance
    exit 0
fi

verify_genuine_fixtures
verify_fixture_timing_provenance

run_case pass 0 'Running observability suite' yes propagated
run_case unmapped 0 'Running observability suite' yes propagated false
run_case absent-managed 0 'Running observability suite' yes propagated
run_case assertion-failure 0 'preserving JUnit and continuing downstream P2P steps' yes propagated
run_case assertion-panicked-message 0 'preserving JUnit and continuing downstream P2P steps' yes propagated
run_case missing-junit 1 'ERROR: missing Ginkgo CLI JUnit report' no absent
run_case missing-junit-stale 1 'ERROR: missing Ginkgo CLI JUnit report' no absent
run_case missing-json 1 'ERROR: missing private Ginkgo JSON report' no absent
run_case malformed-junit 1 'ERROR: malformed or unreadable JUnit:' yes absent
run_case malformed-json 1 'ERROR: malformed or unreadable private Ginkgo JSON:' yes propagated
run_case inconsistent-report 1 'ERROR: JUnit testcase 0 disagrees with JSON State' yes propagated
run_case zero-executed 1 'ERROR: Ginkgo focus/skip matched no executed It specs' yes propagated
run_case skipped-pending 1 'ERROR: Ginkgo focus/skip matched no executed It specs' yes propagated
run_case runner-error 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case panic 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case timedout 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case aborted 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case before-each-failure 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case after-each-additional 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case defer-cleanup-additional 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case cleanup-panic 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case suite-missing-success 1 'ERROR: report 0 has missing or non-boolean SuiteSucceeded' yes propagated
run_case suite-nonboolean-success 1 'ERROR: report 0 has missing or non-boolean SuiteSucceeded' yes propagated
run_case suite-false-with-pass 1 'ERROR: report 0 has incoherent SuiteSucceeded' yes propagated
run_case suite-true-with-failure 1 'ERROR: report 0 has incoherent SuiteSucceeded' yes propagated
run_case special-suite-reason 1 'ERROR: report 0 records a special suite failure' yes propagated
run_case passed-with-failure 1 'ERROR: SpecReport 0 passed with a Failure' yes propagated
run_case xml-failure-skipped 1 'ERROR: JUnit testcase 0 has elements inconsistent with failure State' yes propagated
run_case xml-error-skipped 1 'ERROR: JUnit testcase 0 has elements inconsistent with error State' yes propagated
run_case xml-failure-wrong-type 1 'ERROR: JUnit testcase 0 failure type disagrees with JSON State' yes propagated
run_case xml-error-wrong-type 1 'ERROR: JUnit testcase 0 error type disagrees with JSON State' yes propagated
run_case additional-false-object 1 'ERROR: SpecReport 0 nested AdditionalFailure has invalid State' yes propagated
run_case additional-false-array 1 'ERROR: SpecReport 0 nested AdditionalFailure must be an AdditionalFailure object' yes propagated
run_case additional-false-zero 1 'ERROR: SpecReport 0 nested AdditionalFailure must be an AdditionalFailure object' yes propagated
run_case additional-false-string 1 'ERROR: SpecReport 0 nested AdditionalFailure must be an AdditionalFailure object' yes propagated
run_case forwarded-empty 1 'ERROR: SpecReport 0 has malformed ForwardedPanic' yes propagated
run_case forwarded-zero 1 'ERROR: SpecReport 0 has malformed ForwardedPanic' yes propagated
run_case nested-additional-invalid 1 'ERROR: SpecReport 0 AdditionalFailure 0 nested AdditionalFailure has invalid State' yes propagated
run_case nested-valid-fatal 1 'ERROR: Ginkgo recorded 1 setup, cleanup, timeout, abort, interruption, or panic failure(s)' yes propagated
run_case skipped-forwarded-empty 1 'ERROR: SpecReport 1 has malformed ForwardedPanic' yes propagated
run_case skipped-forwarded-zero 1 'ERROR: SpecReport 1 has malformed ForwardedPanic' yes propagated
run_case skipped-forwarded-valid 1 'ERROR: SpecReport 1 has failure-only fields without a primary failure State' yes propagated
run_case skipped-additional-empty 1 'ERROR: SpecReport 1 nested AdditionalFailure has invalid State' yes propagated
run_case skipped-additional-zero 1 'ERROR: SpecReport 1 nested AdditionalFailure must be an AdditionalFailure object' yes propagated
run_case skipped-additional-nested 1 'ERROR: SpecReport 1 nested AdditionalFailure nested AdditionalFailure has invalid State' yes propagated
run_case skipped-additional-valid 1 'ERROR: SpecReport 1 has failure-only fields without a primary failure State' yes propagated
run_case signal-timeout 1 'ordinary assertion failures require runner exit 1' yes propagated
run_case build-timeout 1 'ERROR: observability suite build failed' no absent
run_case compile-failure 1 'ERROR: observability suite build failed (exit=42)' no absent
run_case go-version-mismatch 1 'ERROR: observability suite build failed (exit=1)' no absent
run_case ginkgo-version-mismatch 1 'ERROR: observability suite build failed (exit=1)' no absent
run_case early-init-failure 58 '' no absent
run_case cleanup-propagation-failure 1 'ERROR: cleanup could not propagate canonical JUnit' yes local-only
run_case cleanup-propagation-prior-failure 42 'ERROR: cleanup could not propagate canonical JUnit' yes local-only
run_case cleanup-removal-prior-failure 42 'ERROR: cleanup could not remove private work root' yes propagated

echo "${passCount} focused acm-obs-e2e-run cases passed"
