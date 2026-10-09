#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

umask 002

readonly buildTimeout="${ACM_OBS_BUILD_TIMEOUT:-15m}"
readonly buildKillAfter="${ACM_OBS_BUILD_KILL_AFTER:-30s}"
readonly suiteTimeout="${ACM_OBS_SUITE_TIMEOUT:-6300s}"
readonly wallTimeout="${ACM_OBS_WALL_TIMEOUT:-107m}"
readonly wallKillAfter="${ACM_OBS_WALL_KILL_AFTER:-2m}"
readonly sourceDir="${ACM_OBS_SOURCE_DIR:-/tmp/obs}"

# Define cleanup before creating the private root so the trap can be installed
# on the very next command. Every path is read with an unset-safe default
# because the EXIT trap can run before later declarations complete.
# shellcheck disable=SC2317 # Invoked by the EXIT trap.
cleanup() {
    local rc=$?
    local cleanupRc=0
    local cleanupWorkRoot=${workRoot:-}
    local cleanupSuiteJunit=${suiteJunit:-}
    local cleanupCanonicalJunit=${canonicalJunit:-}
    local cleanupSharedDir=${SHARED_DIR:-}
    trap - EXIT
    set +e

    # The suite has its own hard-coded ReportAfterSuite output. The Ginkgo CLI
    # report is canonical, so never propagate this duplicate.
    if [[ -n "${cleanupSuiteJunit}" ]] && ! rm -f "${cleanupSuiteJunit}"; then
        echo "ERROR: cleanup could not remove duplicate suite JUnit ${cleanupSuiteJunit}" >&2
        cleanupRc=1
    fi

    if [[ -n "${cleanupCanonicalJunit}" && -f "${cleanupCanonicalJunit}" ]]; then
        if [[ -z "${cleanupSharedDir}" ]]; then
            echo "ERROR: cleanup could not propagate canonical JUnit because SHARED_DIR is unset" >&2
            cleanupRc=1
        elif ! mkdir -p "${cleanupSharedDir}/junit"; then
            echo "ERROR: cleanup could not create shared JUnit directory ${cleanupSharedDir}/junit" >&2
            cleanupRc=1
        elif ! cp "${cleanupCanonicalJunit}" "${cleanupSharedDir}/junit/"; then
            echo "ERROR: cleanup could not propagate canonical JUnit to ${cleanupSharedDir}/junit" >&2
            cleanupRc=1
        fi
    fi

    if [[ -n "${cleanupWorkRoot}" ]]; then
        if ! rm -rf "${cleanupWorkRoot}"; then
            echo "ERROR: cleanup could not remove private work root ${cleanupWorkRoot}" >&2
            cleanupRc=1
        elif [[ -e "${cleanupWorkRoot}" ]]; then
            echo "ERROR: cleanup reported success but private work root remains ${cleanupWorkRoot}" >&2
            cleanupRc=1
        fi
    fi

    # Preserve the runner/classifier status. A cleanup failure makes an
    # otherwise successful run fail, but never hides an existing failure.
    if ((rc == 0 && cleanupRc != 0)); then
        rc=${cleanupRc}
    fi
    exit "${rc}"
}

workRoot="$(mktemp -d /tmp/acm-obs-e2e.XXXXXX)"
trap cleanup EXIT
readonly workRoot

readonly repoDir="${workRoot}/repo"
readonly suiteDir="${repoDir}/tests/pkg/tests"
readonly cacheDir="${workRoot}/go"
readonly ginkgoBin="${workRoot}/bin/ginkgo"
readonly privateReportDir="${workRoot}/reports"
readonly privateJunit="${privateReportDir}/cli-results.xml"
readonly privateJson="${privateReportDir}/ginkgo-report.json"
readonly reportDir="${ARTIFACT_DIR}/obs-results"
readonly diagnosticJunit="${reportDir}/cli-results.xml"
readonly canonicalJunit="${ARTIFACT_DIR}/junit_acm-observability.xml"
readonly suiteJunit="${suiteDir}/results.xml"

mkdir -p "${privateReportDir}" "${reportDir}"
# Never let output left by an earlier container attempt satisfy this run's
# report checks or reach a downstream consumer.
rm -f "${diagnosticJunit}" "${canonicalJunit}" \
    "${SHARED_DIR}/junit/$(basename "${canonicalJunit}")"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Use writable kubeconfig paths because OpenShift assigns an arbitrary UID.
[[ -f "${SHARED_DIR}/kubeconfig" ]] || fail "missing hub kubeconfig in SHARED_DIR"
[[ -f "${SHARED_DIR}/acm-obs-options.json" ]] || \
    fail "missing acm-obs-options.json; acm-obs-odf-setup must run first"

readonly kubeDir="${workRoot}/kube"
mkdir -p "${kubeDir}"
cp "${SHARED_DIR}/kubeconfig" "${kubeDir}/config"
export KUBECONFIG="${kubeDir}/config"

unset IMPORT_KUBECONFIG
if [[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    cp "${SHARED_DIR}/managed-cluster-kubeconfig" "${kubeDir}/import-kubeconfig"
    export IMPORT_KUBECONFIG="${kubeDir}/import-kubeconfig"
fi

export OPTIONS="${SHARED_DIR}/acm-obs-options.json"
export REPORT_FILE="${privateJunit}"
export SKIP_INSTALL_STEP='true'
export SKIP_UNINSTALL_STEP='true'
export IS_CANARY_ENV='true'

# The OPP image carries the complete source checkout rather than a precompiled
# workspace binary. Copy all of it so relative fixtures and future source-side
# additions stay available, and make both source and Go caches arbitrary-UID
# writable.
[[ -f "${sourceDir}/go.mod" ]] || fail "missing ${sourceDir}/go.mod in OPP image"
[[ -d "${sourceDir}/tests/pkg/tests" ]] || fail "missing observability test package in OPP image"
[[ -d "${sourceDir}/examples" ]] || fail "missing examples fixtures in OPP image"

mkdir -p "${repoDir}" "${cacheDir}/home" "${cacheDir}/gopath" \
    "${cacheDir}/build" "${cacheDir}/modules" "$(dirname "${ginkgoBin}")"
cp -R "${sourceDir}/." "${repoDir}/"
chmod -R u+rwX "${repoDir}" "${cacheDir}" "$(dirname "${ginkgoBin}")"
rm -f "${suiteDir}"/*.test "${suiteJunit}"

export HOME="${cacheDir}/home"
export GOPATH="${cacheDir}/gopath"
export GOCACHE="${cacheDir}/build"
export GOMODCACHE="${cacheDir}/modules"
export GOFLAGS='-mod=readonly'

goVersion="$(awk '
    $1 == "toolchain" { sub(/^go/, "", $2); print $2; found=1; exit }
    $1 == "go" { fallback=$2 }
    END { if (!found) print fallback }
' "${repoDir}/go.mod")"
ginkgoVersion="$(awk '$1 == "github.com/onsi/ginkgo/v2" { sub(/^v/, "", $2); print $2; exit }' "${repoDir}/go.mod")"

[[ "${goVersion}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "could not derive a complete Go toolchain version from go.mod"
[[ "${ginkgoVersion}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-].*)?$ ]] || \
    fail "could not derive the Ginkgo v2 version from go.mod"

export GOTOOLCHAIN="go${goVersion}+auto"
export EXPECTED_GO_VERSION="go${goVersion}"
export EXPECTED_GINKGO_VERSION="${ginkgoVersion}"
export REPO_DIR="${repoDir}"
export SUITE_DIR="${suiteDir}"
export GINKGO_BIN="${ginkgoBin}"
export ACM_OBS_EFFECTIVE_SUITE_TIMEOUT="${suiteTimeout}"
export ACM_OBS_PRIVATE_REPORT_DIR="${privateReportDir}"
ACM_OBS_PRIVATE_JUNIT_NAME="$(basename "${privateJunit}")"
ACM_OBS_PRIVATE_JSON_NAME="$(basename "${privateJson}")"
export ACM_OBS_PRIVATE_JUNIT_NAME ACM_OBS_PRIVATE_JSON_NAME

fixtureCount=0
while IFS= read -r fixture; do
    [[ -e "${suiteDir}/${fixture}" ]] || fail "missing suite fixture ${fixture}"
    fixtureCount=$((fixtureCount + 1))
done < <(grep -rhoE '\.\./\.\./\.\./examples[^"[:space:]]*' "${suiteDir}" --include='*.go' | sort -u)

{
    printf 'source_path=%s\n' "${sourceDir}"
    if git -C "${repoDir}" rev-parse --verify HEAD >/dev/null 2>&1; then
        printf 'git_head=%s\n' "$(git -C "${repoDir}" rev-parse HEAD)"
    else
        printf 'git_head=unavailable\n'
    fi
    printf 'go_version=%s\n' "${goVersion}"
    printf 'ginkgo_version=%s\n' "${ginkgoVersion}"
    printf 'fixture_paths=%d\n' "${fixtureCount}"
    printf 'build_timeout=%s\n' "${buildTimeout}"
} > "${ARTIFACT_DIR}/acm-obs-source-provenance.txt"

echo "Building observability suite with Go ${goVersion} and Ginkgo ${ginkgoVersion} (budget ${buildTimeout})"
set +e
# shellcheck disable=SC2016 # The child shell expands exported build variables.
timeout --signal=TERM --kill-after="${buildKillAfter}" "${buildTimeout}" bash -c '
    set -euo pipefail
    # Keep the direct child of timeout alive after the process group receives
    # TERM.
    # Otherwise a TERM-ignoring grandchild can outlive the shell, cancel the
    # --kill-after deadline, and hold the build-log pipe open indefinitely.
    # shellcheck disable=SC2317 # Invoked by the TERM trap.
    on_term() {
        trap - TERM
        while :; do sleep 1; done
    }
    trap on_term TERM
    cd "${REPO_DIR}"

    actual_go="$(go env GOVERSION)"
    [[ "${actual_go}" == "${EXPECTED_GO_VERSION}" ]] || {
        echo "ERROR: selected Go ${actual_go}; expected ${EXPECTED_GO_VERSION}" >&2
        exit 1
    }

    # Build from the embedded module graph so no floating CLI/toolchain is
    # selected independently from the suite.
    go build -o "${GINKGO_BIN}" github.com/onsi/ginkgo/v2/ginkgo
    actual_ginkgo="$("${GINKGO_BIN}" version)"
    [[ "${actual_ginkgo}" == *" ${EXPECTED_GINKGO_VERSION}" ]] || {
        echo "ERROR: built ${actual_ginkgo}; expected Ginkgo ${EXPECTED_GINKGO_VERSION}" >&2
        exit 1
    }

    cd "${SUITE_DIR}"
    "${GINKGO_BIN}" build .
    [[ -x ./tests.test ]] || {
        echo "ERROR: Ginkgo did not produce tests.test" >&2
        exit 1
    }
' 2>&1 | tee "${ARTIFACT_DIR}/acm-obs-build.log"
buildRc=${PIPESTATUS[0]}
set -e
((buildRc == 0)) || fail "observability suite build failed (exit=${buildRc})"

# Run from the package directory so ../../../examples fixtures resolve. The
# CLI-owned report has a distinct name from the suite's hard-coded results.xml.
echo "Running observability suite from ${suiteDir} (suite timeout ${suiteTimeout})"
set +e
# shellcheck disable=SC2016 # The child shell expands exported suite variables.
timeout --signal=TERM --kill-after="${wallKillAfter}" "${wallTimeout}" bash -c '
    set -euo pipefail
    # Keep the direct child of timeout alive after TERM even if Ginkgo exits while a
    # test-binary descendant ignores TERM and keeps the log pipe open. This
    # preserves the timeout hard-kill deadline for the entire process group.
    # shellcheck disable=SC2317 # Invoked by the TERM trap.
    on_term() {
        trap - TERM
        while :; do sleep 1; done
    }
    trap on_term TERM
    cd "${SUITE_DIR}"
    "${GINKGO_BIN}" \
        --v \
        --focus="${GINKGO_FOCUS}" \
        --skip="${GINKGO_SKIP}" \
        --timeout="${ACM_OBS_EFFECTIVE_SUITE_TIMEOUT}" \
        --no-color \
        -nodes=1 \
        --output-dir="${ACM_OBS_PRIVATE_REPORT_DIR}" \
        --junit-report="${ACM_OBS_PRIVATE_JUNIT_NAME}" \
        --json-report="${ACM_OBS_PRIVATE_JSON_NAME}" \
        ./tests.test \
        -- -v=3
' 2>&1 | tee "${ARTIFACT_DIR}/acm-obs-test.log"
ginkgoRc=${PIPESTATUS[0]}
set -e

[[ -f "${privateJunit}" ]] || fail "missing Ginkgo CLI JUnit report (exit=${ginkgoRc})"
[[ -f "${privateJson}" ]] || fail "missing private Ginkgo JSON report (exit=${ginkgoRc})"

# Retain the CLI JUnit as a non-harvested diagnostic. The structured JSON can
# contain cluster and test diagnostics, so it stays below workRoot and is
# always removed by the EXIT trap rather than copied to an artifact directory.
cp "${privateJunit}" "${diagnosticJunit}"

# Validate and map the CLI JUnit locally, then classify the private native JSON
# report. ElementTree and json are in the image's Python standard library; no
# remote helper is downloaded or evaluated. The summary is numeric output,
# never shell code.
if ! reportSummary="$(python3 - "${privateJunit}" "${privateJson}" "${canonicalJunit}" "${MAP_TESTS}" "${DR__RP__CR_COMP_NAME}" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

junit_source, json_source, destination, map_tests, component = sys.argv[1:]


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)

try:
    tree = ET.parse(junit_source)
except (ET.ParseError, OSError) as exc:
    die(f"malformed or unreadable JUnit: {exc}")

root = tree.getroot()
if root.tag not in {"testsuite", "testsuites"}:
    die(f"unsupported JUnit root element {root.tag!r}")

suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
if not suites:
    die("JUnit contains no testsuite")

if map_tests.lower() == "true":
    for suite in suites:
        original = suite.get("name", "")
        suite.set("name", f"{component}--{original}")

testcases = list(root.iter("testcase"))
# Preserve the canonical JUnit for reporting even when the structured report
# subsequently proves the run fatal.
tree.write(destination, encoding="utf-8", xml_declaration=True)

try:
    with open(json_source, encoding="utf-8") as stream:
        reports = json.load(stream)
except (json.JSONDecodeError, OSError) as exc:
    die(f"malformed or unreadable private Ginkgo JSON: {exc}")

if not isinstance(reports, list) or not reports:
    die("private Ginkgo JSON root must be a non-empty report array")

valid_states = {
    "passed", "pending", "skipped", "failed", "aborted", "panicked",
    "interrupted", "timedout",
}
failure_states = {"failed", "aborted", "panicked", "interrupted", "timedout"}
valid_node_types = {
    "Container", "It", "BeforeEach", "JustBeforeEach", "AfterEach",
    "JustAfterEach", "BeforeAll", "AfterAll", "BeforeSuite",
    "SynchronizedBeforeSuite", "AfterSuite", "SynchronizedAfterSuite",
    "ReportBeforeEach", "ReportAfterEach", "ReportBeforeSuite",
    "ReportAfterSuite", "DeferCleanup", "DeferCleanup (Each)",
    "DeferCleanup (All)", "DeferCleanup (Suite)",
}


def validate_additional_failure(additional, label):
    if not isinstance(additional, dict):
        die(f"{label} must be an AdditionalFailure object")
    state = additional.get("State")
    if state not in failure_states:
        die(f"{label} has invalid State")
    validate_failure(additional.get("Failure"), label, state)


def validate_failure(failure, label, state):
    if not isinstance(failure, dict):
        die(f"{label} must contain a Failure object")
    context = failure.get("FailureNodeContext")
    node_type = failure.get("FailureNodeType")
    if context not in {"leaf-node", "top-level", "in-container"}:
        die(f"{label} has invalid FailureNodeContext")
    if node_type not in valid_node_types:
        die(f"{label} has invalid FailureNodeType")
    if "ForwardedPanic" in failure:
        forwarded_panic = failure["ForwardedPanic"]
        if not isinstance(forwarded_panic, str) or not forwarded_panic:
            die(f"{label} has malformed ForwardedPanic")
    if state == "panicked" and "ForwardedPanic" not in failure:
        die(f"{label} panicked without ForwardedPanic")
    if "AdditionalFailure" in failure:
        validate_additional_failure(
            failure["AdditionalFailure"], f"{label} nested AdditionalFailure"
        )


specs = []
for report_index, report in enumerate(reports):
    if not isinstance(report, dict):
        die(f"report {report_index} is not an object")
    if "SuiteSucceeded" not in report or type(report["SuiteSucceeded"]) is not bool:
        die(f"report {report_index} has missing or non-boolean SuiteSucceeded")
    reasons = report.get("SpecialSuiteFailureReasons")
    if reasons is not None and not isinstance(reasons, list):
        die(f"report {report_index} has malformed SpecialSuiteFailureReasons")
    if reasons:
        die(f"report {report_index} records a special suite failure")
    report_specs = report.get("SpecReports")
    if not isinstance(report_specs, list):
        die(f"report {report_index} has no SpecReports array")
    report_has_failure = any(
        isinstance(spec, dict) and spec.get("State") in failure_states
        for spec in report_specs
    )
    if report["SuiteSucceeded"] == report_has_failure:
        die(f"report {report_index} has incoherent SuiteSucceeded")
    specs.extend(report_specs)

if len(specs) != len(testcases):
    die("JUnit testcase count does not match private Ginkgo SpecReports")

executed = 0
ordinary_failures = 0
fatal_failures = 0
for spec_index, (spec, case) in enumerate(zip(specs, testcases)):
    if not isinstance(spec, dict):
        die(f"SpecReport {spec_index} is not an object")
    leaf_type = spec.get("LeafNodeType")
    state = spec.get("State")
    if leaf_type not in valid_node_types:
        die(f"SpecReport {spec_index} has invalid LeafNodeType")
    if state not in valid_states:
        die(f"SpecReport {spec_index} has invalid State")
    if not case.get("name", "").startswith(f"[{leaf_type}]"):
        die(f"JUnit testcase {spec_index} disagrees with JSON LeafNodeType")
    if case.get("status") != state:
        die(f"JUnit testcase {spec_index} disagrees with JSON State")

    failures = case.findall("failure")
    errors = case.findall("error")
    skipped = case.findall("skipped")
    if state in {"passed"} and (failures or errors or skipped):
        die(f"JUnit testcase {spec_index} has elements inconsistent with passed State")
    if state in {"pending", "skipped"} and (failures or errors or len(skipped) != 1):
        die(f"JUnit testcase {spec_index} has elements inconsistent with skipped State")
    if state in {"failed", "timedout", "aborted"} and (
        len(failures) != 1 or errors or skipped
    ):
        die(f"JUnit testcase {spec_index} has elements inconsistent with failure State")
    if state in {"panicked", "interrupted"} and (
        failures or len(errors) != 1 or skipped
    ):
        die(f"JUnit testcase {spec_index} has elements inconsistent with error State")
    if failures and failures[0].get("type") != state:
        die(f"JUnit testcase {spec_index} failure type disagrees with JSON State")
    if errors and errors[0].get("type") != state:
        die(f"JUnit testcase {spec_index} error type disagrees with JSON State")

    failure = None
    if "Failure" in spec:
        failure = spec["Failure"]
        validate_failure(failure, f"SpecReport {spec_index}", state)
        if state == "passed":
            die(f"SpecReport {spec_index} passed with a Failure")
        if state not in failure_states and (
            "ForwardedPanic" in failure or "AdditionalFailure" in failure
        ):
            die(
                f"SpecReport {spec_index} has failure-only fields without "
                "a primary failure State"
            )
    elif state in failure_states:
        die(f"SpecReport {spec_index} must contain a Failure object")

    additional = spec.get("AdditionalFailures", [])
    if not isinstance(additional, list):
        die(f"SpecReport {spec_index} has malformed AdditionalFailures")
    for additional_index, item in enumerate(additional):
        validate_additional_failure(
            item,
            f"SpecReport {spec_index} AdditionalFailure {additional_index}",
        )

    if leaf_type == "It" and state not in {"pending", "skipped"}:
        executed += 1
    if state in failure_states:
        is_body_assertion = (
            leaf_type == "It"
            and state == "failed"
            and failure.get("FailureNodeContext") == "leaf-node"
            and failure.get("FailureNodeType") == "It"
            and "ForwardedPanic" not in failure
            and "AdditionalFailure" not in failure
            and not additional
        )
        if is_body_assertion:
            ordinary_failures += 1
        else:
            fatal_failures += 1
    elif additional:
        die(f"SpecReport {spec_index} has AdditionalFailures without a primary failure State")

print(executed, ordinary_failures, fatal_failures)
PY
)"; then
    fail "JUnit/JSON validation or mapping failed"
fi

rm -f "${privateJson}"
read -r executedCount failureCount fatalFailureCount <<< "${reportSummary}"
((executedCount > 0)) || fail "Ginkgo focus/skip matched no executed It specs"
((fatalFailureCount == 0)) || \
    fail "Ginkgo recorded ${fatalFailureCount} setup, cleanup, timeout, abort, interruption, or panic failure(s)"

# Ordinary, valid assertion failures are intentionally non-gating for this P2P
# sequence so later product tests still run. Missing/malformed/empty reports,
# runner errors, panics, and nonzero exits without assertion failures are fatal.
if ((failureCount > 0)); then
    ((ginkgoRc == 1)) || \
        fail "Ginkgo exited ${ginkgoRc}; ordinary assertion failures require runner exit 1"
    echo "Ginkgo recorded ${failureCount} assertion failure(s); preserving JUnit and continuing downstream P2P steps"
elif ((ginkgoRc != 0)); then
    fail "Ginkgo exited ${ginkgoRc} without an ordinary assertion failure"
fi

exit 0
