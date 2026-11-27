#!/bin/bash

# Offline regression tests for the ROSA HCP readiness wait step.
#
# The step emits a diagnostics artifact into the publicly retained Prow
# ARTIFACT_DIR when the pod readiness wait does not succeed. These tests drive
# the real command script with mocked `ocm`, `oc` and `sleep` binaries so that
# no cluster, credential or network access is required, and assert that:
#   * a successful wait is unchanged and writes no diagnostics
#   * poll and shared-deadline behavior is unchanged
#   * an unsuccessful wait captures diagnostics and still fails the same way
#   * unavailable, failed and malformed collection is reported separately
#   * the artifact only ever contains the agreed field and value allowlist

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STEP_DIR="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster/wait-ready/hosted-cp"
COMMAND_SCRIPT="${STEP_DIR}/rosa-cluster-wait-ready-hosted-cp-commands.sh"
REF_FILE="${STEP_DIR}/rosa-cluster-wait-ready-hosted-cp-ref.yaml"
TEST_ROOT=$(mktemp -d)

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

CLUSTER_ID="2abc3def4ghi"
CLUSTER_NAME="mycluster"
HCP_NAMESPACE="ocm-staging-${CLUSTER_ID}-${CLUSTER_NAME}"
HC_NAMESPACE="ocm-staging-${CLUSTER_ID}"

# Sentinels planted in every mocked API response. None of them may ever reach
# the artifact, and the credential sentinels may not reach the log either.
SENSITIVE_VALUES=(
  'SENSITIVEPODNAME'
  'SENSITIVECONTAINER'
  'SENSITIVEIMAGE'
  'SENSITIVENODE'
  'SENSITIVEUID'
  'SENSITIVELABEL'
  'SENSITIVEANNOTATION'
  'SENSITIVECONDITIONMESSAGE'
  'SENSITIVEEVENTMESSAGE'
  'SENSITIVEFIELDPATH'
  'SENSITIVEKUBECONFIG'
  'SENSITIVEOCMTOKEN'
)
CREDENTIAL_VALUES=(
  'SENSITIVEKUBECONFIG'
  'SENSITIVEOCMTOKEN'
)

# Structural keys the artifact is allowed to use.
ARTIFACT_KEYS=(
  schemaVersion kind trigger collectedAt waitTimeoutSeconds waitElapsedSeconds
  minimumExpectedPods lastPoll podQuery podCount podCountBelowMinimum
  collection pods status observed reported unparsableItems truncated
  events observedPodEvents reportedGroups summary podsByPhase podsNotReady
  alias phase reason creationTimestamp startTime conditions type
  lastTransitionTime containers initContainers total ready restartsTotal
  restartsMax byState running waiting terminated unknown waitingReasons
  terminatedReasons count firstTimestamp lastTimestamp unmatchedPodEvents notes
)

# Fixed strings the artifact is allowed to emit, beyond the enum allowlists.
ARTIFACT_FIXED_STRINGS=(
  ROSAHCPPodDiagnostics
  pod-readiness-wait-failed
  Other
  ok unavailable malformed oversized
  succeeded failed not-run
  pod-collection-unavailable pod-collection-malformed pod-collection-oversized
  event-collection-unavailable event-collection-malformed event-collection-oversized
  last-poll-pod-query-failed last-poll-pod-query-not-run
  last-poll-pod-count-below-minimum
  pod-list-truncated
  pod-items-unparsable
  diagnostics-rendering-failed
)

# These must stay byte-identical to the allowlists in the command script.
CONDITION_TYPES='["PodReadyToStartContainers","Initialized","Ready","ContainersReady","PodScheduled","DisruptionTarget"]'
CONDITION_STATUSES='["True","False","Unknown"]'
CONDITION_REASONS='["ContainersNotInitialized","ContainersNotReady","PodCompleted","PodFailed","PodTerminating","ReadinessGatesNotReady","SchedulingGated","Unschedulable","PreemptionByScheduler","DeletionByTaintManager","DeletionByPodGC","EvictionByEvictionAPI","TerminationByKubelet"]'
POD_PHASES='["Pending","Running","Succeeded","Failed","Unknown"]'
POD_REASONS='["Evicted","NodeAffinity","NodeLost","Shutdown","Preempting","Terminated","UnexpectedAdmissionError","OutOfcpu","OutOfmemory","OutOfpods","OutOfephemeral-storage"]'
WAITING_REASONS='["ContainerCreating","PodInitializing","CrashLoopBackOff","ImagePullBackOff","ErrImagePull","ErrImageNeverPull","ImageInspectError","InvalidImageName","RegistryUnavailable","SignatureValidationFailed","CreateContainerConfigError","CreateContainerError","RunContainerError","PreStartHookError","PostStartHookError","StartError","ContainerCannotRun","DeadlineExceeded","ContainerStatusUnknown"]'
TERMINATED_REASONS='["Completed","Error","OOMKilled","ContainerCannotRun","DeadlineExceeded","Evicted","StartError","ContainerStatusUnknown","PreStartHookError","PostStartHookError"]'
EVENT_TYPES='["Normal","Warning"]'
EVENT_REASONS='["Scheduled","FailedScheduling","Preempted","Pulling","Pulled","Failed","InspectFailed","ErrImageNeverPull","BackOff","Created","Started","Killing","Unhealthy","ProbeWarning","FailedMount","FailedAttachVolume","FailedCreatePodSandBox","FailedCreatePodContainer","FailedPostStartHook","FailedPreStopHook","SandboxChanged","NetworkNotReady","NodeNotReady","Evicted","ExceededGracePeriod","FailedKillPod","FailedSync","OOMKilling","TaintManagerEviction","VolumeResizeFailed","FileSystemResizeFailed"]'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,200p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "${unexpected}" "${file}"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_json() {
  local artifact="$1" filter="$2" expected="$3" actual
  actual=$(jq -r "${filter}" "${artifact}")
  [[ "${actual}" == "${expected}" ]] || fail "expected ${filter} to be '${expected}', got '${actual}' in ${artifact}"
}

artifact_path() {
  local case_dir="$1"
  local -a found=()
  while IFS= read -r candidate; do
    found+=("${candidate}")
  done < <(find "${case_dir}/artifacts" -maxdepth 1 -name 'rosa-hcp-pod-diagnostics-*.json' -type f 2>/dev/null | sort)
  [[ "${#found[@]}" == "1" ]] || fail "expected exactly one diagnostics artifact in ${case_dir}/artifacts, found ${#found[@]}"
  printf '%s\n' "${found[0]}"
}

assert_no_artifact() {
  local case_dir="$1" count
  count=$(find "${case_dir}/artifacts" -maxdepth 1 -name 'rosa-hcp-pod-diagnostics-*.json' -type f 2>/dev/null | wc -l)
  [[ "${count}" == "0" ]] || fail "expected no diagnostics artifact in ${case_dir}/artifacts, found ${count}"
}

assert_no_sensitive_values() {
  local file="$1" value
  for value in "${SENSITIVE_VALUES[@]}"; do
    assert_not_contains "${file}" "${value}"
  done
}

assert_no_credentials() {
  local file="$1" value
  for value in "${CREDENTIAL_VALUES[@]}"; do
    assert_not_contains "${file}" "${value}"
  done
}

# Prow publishes everything left in ARTIFACT_DIR, so the sanitized artifact
# must be the only thing there: no scratch directory, no raw API dump, no
# empty leftover.
assert_artifact_dir_holds_only_the_artifact() {
  local case_dir="$1" entries
  entries=$(find "${case_dir}/artifacts" -mindepth 1 | wc -l)
  if [[ "${entries}" != "1" ]]; then
    find "${case_dir}/artifacts" -mindepth 1 >&2
    fail "expected ARTIFACT_DIR to hold only the diagnostics artifact, found ${entries} entries"
  fi
  if grep -rlE 'SENSITIVE[A-Z]+' "${case_dir}/artifacts" > /dev/null 2>&1; then
    fail "raw collected data was left in ARTIFACT_DIR"
  fi
}

# Cleaning up afterwards is not enough: a step killed mid-collection publishes
# whatever is still on disk, so the raw dumps must never be created under
# ARTIFACT_DIR in the first place. The renderer is handed the scratch paths, so
# its recorded arguments show where they really were.
assert_scratch_files_were_outside_the_artifact_dir() {
  local case_dir="$1" slurp_lines
  slurp_lines=$(grep -c -- '--slurpfile' "${case_dir}/state/jq-invocations" || true)
  [[ "${slurp_lines}" -ge 1 ]] || fail "the renderer was never handed any scratch file"
  if grep -- '--slurpfile' "${case_dir}/state/jq-invocations" \
     | grep -F -- "${case_dir}/artifacts/" > /dev/null; then
    grep -- '--slurpfile' "${case_dir}/state/jq-invocations" >&2
    fail "raw scratch files were created inside ARTIFACT_DIR"
  fi
}

# Every string that appears in the artifact, as a value or as an object key,
# must come from the agreed allowlist, be a run-local pod alias, or be an
# RFC3339 timestamp. Nothing else may ever be published.
assert_artifact_vocabulary() {
  local artifact="$1" token
  local -A allowed=()
  local -a offenders=()

  for token in "${ARTIFACT_KEYS[@]}" "${ARTIFACT_FIXED_STRINGS[@]}"; do
    allowed["${token}"]=1
  done
  while IFS= read -r token; do
    # Nothing free-form may be allowlisted in: every enum value has to look
    # like an enum value, so widening an allowlist cannot smuggle in text.
    [[ "${token}" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] || fail "allowlist entry '${token}' is not a bare enum identifier"
    allowed["${token}"]=1
  done < <(jq -r --argjson sets "[${CONDITION_TYPES},${CONDITION_STATUSES},${CONDITION_REASONS},${POD_PHASES},${POD_REASONS},${WAITING_REASONS},${TERMINATED_REASONS},${EVENT_TYPES},${EVENT_REASONS}]" \
    -n '$sets | add | unique[]')

  while IFS= read -r token; do
    if [[ "${token}" =~ ^pod-[0-9]{3}$ ]]; then
      continue
    fi
    if [[ "${token}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
      continue
    fi
    if [[ -n "${allowed[${token}]:-}" ]]; then
      continue
    fi
    offenders+=("${token}")
  done < <(jq -r '[ (.. | strings), (.. | objects | keys[]) ] | unique[]' "${artifact}")

  [[ "${#offenders[@]}" == "0" ]] || fail "artifact contains values outside the allowlist: ${offenders[*]}"
}

assert_valid_json() {
  local file="$1"
  jq -e 'type == "object"' "${file}" > /dev/null 2>&1 || fail "${file} is not a JSON object"
}

make_fixtures() {
  local dir="$1"
  mkdir -p "${dir}"

  cat > "${dir}/pods-unready.json" <<EOF
{"apiVersion":"v1","kind":"List","items":[
 {"metadata":{"name":"SENSITIVEPODNAME-1","namespace":"${HCP_NAMESPACE}","uid":"SENSITIVEUID-0000-0000-0000-000000000001",
   "creationTimestamp":"2026-11-25T10:00:00Z","labels":{"app":"SENSITIVELABEL"},"annotations":{"note":"SENSITIVEANNOTATION"}},
  "spec":{"nodeName":"SENSITIVENODE"},
  "status":{"phase":"Pending","startTime":"2026-11-25T10:00:05Z",
   "conditions":[
    {"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"SENSITIVECONDITIONMESSAGE","lastTransitionTime":"2026-11-25T10:00:06Z"},
    {"type":"Ready","status":"False","reason":"ContainersNotReady","message":"SENSITIVECONDITIONMESSAGE","lastTransitionTime":"2026-11-25T10:00:07Z"},
    {"type":"SomeUnknownFutureCondition","status":"Whatever","reason":"SENSITIVECONDITIONMESSAGE"}],
   "containerStatuses":[
    {"name":"SENSITIVECONTAINER","image":"SENSITIVEIMAGE:v1","ready":false,"restartCount":7,
     "state":{"waiting":{"reason":"CrashLoopBackOff","message":"SENSITIVECONDITIONMESSAGE"}}},
    {"name":"SENSITIVECONTAINER-2","image":"SENSITIVEIMAGE:v2","ready":false,"restartCount":2,
     "state":{"waiting":{"reason":"SomeBrandNewReason","message":"SENSITIVECONDITIONMESSAGE"}}}],
   "initContainerStatuses":[
    {"name":"SENSITIVECONTAINER-init","ready":true,"restartCount":1,
     "state":{"terminated":{"reason":"Completed","exitCode":0,"message":"SENSITIVECONDITIONMESSAGE"}}}]}},
 {"metadata":{"name":"SENSITIVEPODNAME-2","uid":"SENSITIVEUID-0000-0000-0000-000000000002","creationTimestamp":"2026-11-25T10:00:00Z"},
  "status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],
   "containerStatuses":[{"name":"SENSITIVECONTAINER-3","ready":true,"restartCount":0,"state":{"running":{"startedAt":"2026-11-25T10:01:00Z"}}}]}},
 {"metadata":{"name":"SENSITIVEPODNAME-3","uid":1234},"status":{"phase":"Running"}},
 "SENSITIVEPODNAME-not-an-object"
]}
EOF

  cat > "${dir}/events.json" <<'EOF'
{"apiVersion":"v1","kind":"List","items":[
 {"involvedObject":{"kind":"Pod","name":"SENSITIVEPODNAME-1","uid":"SENSITIVEUID-0000-0000-0000-000000000001","fieldPath":"SENSITIVEFIELDPATH"},
  "type":"Warning","reason":"FailedScheduling","count":3,"message":"SENSITIVEEVENTMESSAGE",
  "firstTimestamp":"2026-11-25T10:00:10Z","lastTimestamp":"2026-11-25T10:05:10Z",
  "source":{"component":"SENSITIVENODE"},"reportingInstance":"SENSITIVENODE"},
 {"involvedObject":{"kind":"Pod","name":"SENSITIVEPODNAME-1","uid":"SENSITIVEUID-0000-0000-0000-000000000001"},
  "type":"Warning","reason":"FailedScheduling","count":2,"message":"SENSITIVEEVENTMESSAGE",
  "firstTimestamp":"2026-11-25T10:00:20Z","lastTimestamp":"2026-11-25T10:04:00Z"},
 {"involvedObject":{"kind":"Pod","name":"SENSITIVEPODNAME-1","uid":"SENSITIVEUID-0000-0000-0000-000000000001"},
  "type":"Warning","reason":"BackOff","count":12,"message":"SENSITIVEEVENTMESSAGE",
  "firstTimestamp":"2026-11-25T10:06:00Z","lastTimestamp":"2026-11-25T10:20:00Z"},
 {"involvedObject":{"kind":"Pod","name":"SENSITIVEPODNAME-1","uid":"SENSITIVEUID-0000-0000-0000-000000000001"},
  "type":"SomeNewType","reason":"SomeBrandNewEventReason","count":1,"message":"SENSITIVEEVENTMESSAGE",
  "eventTime":"2026-11-25T10:07:00Z"},
 {"involvedObject":{"kind":"Pod","name":"SENSITIVEPODNAME-9","uid":"SENSITIVEUID-0000-0000-0000-000000000009"},
  "type":"Normal","reason":"Killing","count":2,"message":"SENSITIVEEVENTMESSAGE",
  "firstTimestamp":"2026-11-25T10:03:00Z","lastTimestamp":"2026-11-25T10:03:30Z"},
 {"involvedObject":{"kind":"Deployment","name":"SENSITIVEPODNAME-deploy","uid":"SENSITIVEUID-dep"},
  "type":"Normal","reason":"ScalingReplicaSet","count":1,"message":"SENSITIVEEVENTMESSAGE"}
]}
EOF

  {
    printf 'SENSITIVEPODNAME-1   0/2   CrashLoopBackOff   7   5m   10.0.0.1   SENSITIVENODE\n'
    local i
    for i in $(seq 2 12); do
      printf 'SENSITIVEPODNAME-%s   1/1   Running   0   5m   10.0.0.%s   SENSITIVENODE\n' "${i}" "${i}"
    done
  } > "${dir}/pods-unready.txt"

  {
    local i
    for i in $(seq 1 12); do
      printf 'SENSITIVEPODNAME-%s   1/1   Running   0   5m   10.0.0.%s   SENSITIVENODE\n' "${i}" "${i}"
    done
  } > "${dir}/pods-ready.txt"

  {
    local i
    for i in $(seq 1 3); do
      printf 'SENSITIVEPODNAME-%s   1/1   Running   0   5m   10.0.0.%s   SENSITIVENODE\n' "${i}" "${i}"
    done
  } > "${dir}/pods-few.txt"

  printf 'this is not SENSITIVEPODNAME json at all\n' > "${dir}/pods-garbage.json"
  printf '{"items": "SENSITIVEPODNAME"}\n' > "${dir}/events-garbage.json"
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-invocations"
case "$*" in
  login*)
    exit 0 ;;
  *provision_shard*)
    printf '{"management_cluster":"mc-SENSITIVENODE"}\n' ;;
  *credentials*)
    printf '{"kubeconfig":"SENSITIVEKUBECONFIG"}\n' ;;
  *--parameter*)
    printf '{"items":[{"id":"mcid-0001"}]}\n' ;;
  *)
    printf '{"name":"%s"}\n' "${MOCK_CLUSTER_NAME}" ;;
esac
exit 0
EOF

  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash
state="${MOCK_STATE_DIR}"
fixtures="${MOCK_FIXTURE_DIR}"
printf '%s\n' "$*" >> "${state}/oc-invocations"

bump() {
  local name="$1" value=0
  [[ ! -f "${state}/${name}" ]] || value=$(cat "${state}/${name}")
  value=$(( value + 1 ))
  printf '%s\n' "${value}" > "${state}/${name}"
  printf '%s\n' "${value}"
}

case "$*" in
  whoami*)
    printf 'system:serviceaccount:mock\n'
    exit 0 ;;
  *hostedcluster*Degraded*|*hostedcontrolplane*Degraded*)
    printf 'False'
    exit 0 ;;
  *hostedcluster*Available*|*hostedcontrolplane*Available*)
    printf 'True'
    exit 0 ;;
  *hostedcontrolplane*.status.ready*)
    printf 'true'
    exit 0 ;;
  *vpcendpoints*)
    printf 'available'
    exit 0 ;;
  *"get pods"*--no-headers*)
    attempt=$(bump pod-list-attempts)
    case "${MOCK_SCENARIO}" in
      pod_list_error)
        exit 1 ;;
      too_few_pods)
        cat "${fixtures}/pods-few.txt" ;;
      success)
        cat "${fixtures}/pods-ready.txt" ;;
      recovers)
        if [[ "${attempt}" -ge 2 ]]; then
          cat "${fixtures}/pods-ready.txt"
        else
          cat "${fixtures}/pods-unready.txt"
        fi ;;
      last_poll_wins)
        # First poll sees too few pods, every later poll fails outright, so the
        # reported lastPoll fields must describe the later poll.
        if [[ "${attempt}" -ge 2 ]]; then
          exit 1
        fi
        cat "${fixtures}/pods-few.txt" ;;
      *)
        cat "${fixtures}/pods-unready.txt" ;;
    esac
    exit 0 ;;
  *"get pods"*-o\ json*)
    bump pod-json-attempts > /dev/null
    case "${MOCK_SCENARIO}" in
      pod_list_error|pod_json_error|last_poll_wins)
        exit 1 ;;
      pod_json_malformed)
        cat "${fixtures}/pods-garbage.json" ;;
      pod_json_oversized)
        # Valid JSON, but past HCP_DIAG_MAX_INPUT_BYTES, so it must be rejected
        # on size alone before the renderer ever parses it.
        printf '{"items":[]}'
        head -c 34000000 /dev/zero | tr '\0' ' ' ;;
      *)
        cat "${fixtures}/pods-unready.json" ;;
    esac
    exit 0 ;;
  *"get events"*-o\ json*)
    bump event-json-attempts > /dev/null
    case "${MOCK_SCENARIO}" in
      event_json_error)
        exit 1 ;;
      pod_json_malformed)
        cat "${fixtures}/events-garbage.json" ;;
      *)
        cat "${fixtures}/events.json" ;;
    esac
    exit 0 ;;
  *"get pods"*-o\ wide*)
    cat "${fixtures}/pods-ready.txt"
    exit 0 ;;
esac
printf 'unexpected oc invocation: %s\n' "$*" >&2
exit 1
EOF

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  # Delegates to the real jq except where a scenario needs the rendering step
  # itself to fail; the production code depends on a working jq everywhere else.
  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
# Recording the arguments exposes where the scratch files actually live, which
# is otherwise invisible once the collector has cleaned up after itself.
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/jq-invocations"
if [[ "${MOCK_SCENARIO}" == "render_failure" ]]; then
  for arg in "$@"; do
    if [[ "${arg}" == "-f" ]]; then
      printf 'mock jq refusing to render\n' >&2
      exit 3
    fi
  done
fi
exec "${MOCK_REAL_JQ}" "$@"
EOF

  # Only the epoch reader is faked, and only where a scenario needs a
  # deterministic number of polls; every other format goes to the real date.
  cat > "${mock_dir}/date" <<'EOF'
#!/bin/bash
if [[ "${MOCK_SCENARIO}" == "last_poll_wins" && "$*" == "+%s" ]]; then
  tick=0
  [[ ! -f "${MOCK_STATE_DIR}/clock" ]] || tick=$(cat "${MOCK_STATE_DIR}/clock")
  printf '%s\n' "$(( tick + 1 ))" > "${MOCK_STATE_DIR}/clock"
  printf '%s\n' "$(( tick * 30 ))"
  exit 0
fi
exec "${MOCK_REAL_DATE}" "$@"
EOF

  chmod +x "${mock_dir}"/*
}

# Runs the real command script fully offline. Returns its exit status.
run_script() {
  local scenario="$1" case_dir="$2" timeout="${3:-0}" with_artifact_dir="${4:-true}"
  local mock_dir="${case_dir}/bin" real_jq real_date
  local -a artifact_env=()
  local -a tmpdir_env=()

  real_jq=$(command -v jq)
  real_date=$(command -v date)
  mkdir -p "${case_dir}/state" "${case_dir}/shared" "${case_dir}/profile" "${case_dir}/artifacts"
  make_fixtures "${case_dir}/fixtures"
  make_mocks "${mock_dir}"
  printf 'SENSITIVEOCMTOKEN' > "${case_dir}/profile/ocm-token"
  printf '%s' "${CLUSTER_ID}" > "${case_dir}/shared/cluster-id"
  [[ "${with_artifact_dir}" != "true" ]] || artifact_env=(ARTIFACT_DIR="${case_dir}/artifacts")
  [[ "${scenario}" != "artifact_dir_readonly" ]] || chmod 0555 "${case_dir}/artifacts"
  # A hostile TMPDIR must not be able to steer the raw API dumps into the
  # published artifacts directory.
  [[ "${scenario}" != "tmpdir_in_artifact_dir" ]] || tmpdir_env=(TMPDIR="${case_dir}/artifacts")

  env \
    ${artifact_env[@]+"${artifact_env[@]}"} \
    ${tmpdir_env[@]+"${tmpdir_env[@]}"} \
    PATH="${mock_dir}:${PATH}" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_FIXTURE_DIR="${case_dir}/fixtures" \
    MOCK_CLUSTER_NAME="${CLUSTER_NAME}" \
    MOCK_REAL_JQ="${real_jq}" \
    MOCK_REAL_DATE="${real_date}" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    SHARED_DIR="${case_dir}/shared" \
    OCM_LOGIN_ENV=staging \
    HCP_READY_TIMEOUT="${timeout}" \
    bash "${COMMAND_SCRIPT}" > "${case_dir}/output.log" 2>&1
}

run_case() {
  local scenario="$1" case_dir="$2" timeout="${3:-0}" with_artifact_dir="${4:-true}"
  local rc=0
  mkdir -p "${case_dir}"
  set +e
  run_script "${scenario}" "${case_dir}" "${timeout}" "${with_artifact_dir}"
  rc=$?
  set -e
  [[ "${scenario}" != "artifact_dir_readonly" ]] || chmod 0755 "${case_dir}/artifacts"
  printf '%s\n' "${rc}"
}

test_ref_declares_wait_contract() {
  # The diagnostics path reuses the step's existing timeout contract; a change
  # to either default would silently change the shared deadline.
  assert_contains "${REF_FILE}" 'name: HCP_READY_TIMEOUT'
  assert_contains "${REF_FILE}" 'default: "1800"'
  assert_contains "${REF_FILE}" 'name: OCM_LOGIN_ENV'
}

test_allowlists_match_the_command_script() {
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_CONDITION_TYPES='${CONDITION_TYPES}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_CONDITION_STATUSES='${CONDITION_STATUSES}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_CONDITION_REASONS='${CONDITION_REASONS}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_POD_PHASES='${POD_PHASES}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_POD_REASONS='${POD_REASONS}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_WAITING_REASONS='${WAITING_REASONS}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_TERMINATED_REASONS='${TERMINATED_REASONS}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_EVENT_TYPES='${EVENT_TYPES}'"
  assert_contains "${COMMAND_SCRIPT}" "HCP_DIAG_EVENT_REASONS='${EVENT_REASONS}'"
}

test_successful_wait_is_unchanged() {
  local case_dir="${TEST_ROOT}/success" rc
  rc=$(run_case success "${case_dir}" 1800)
  assert_status "${rc}" 0 "successful readiness wait"
  assert_contains "${case_dir}/output.log" "All HostedControlPlane readiness checks passed"
  assert_contains "${case_dir}/output.log" "PASSED: all pods ready in ${HCP_NAMESPACE}"
  assert_contains "${case_dir}/output.log" "PASSED: VpcEndpoint 'private-hcp' in ${HCP_NAMESPACE}"
  assert_contains "${case_dir}/output.log" "PASSED: HostedCluster '${CLUSTER_NAME}' in ${HC_NAMESPACE}"
  assert_no_artifact "${case_dir}"
  assert_not_contains "${case_dir}/output.log" "HCP pod diagnostics"
  assert_no_credentials "${case_dir}/output.log"
  [[ ! -f "${case_dir}/state/pod-json-attempts" ]] || fail "diagnostics were collected on the success path"
  [[ ! -f "${case_dir}/state/event-json-attempts" ]] || fail "events were collected on the success path"
}

test_poll_behavior_and_shared_deadline_are_unchanged() {
  local case_dir="${TEST_ROOT}/recovers" rc
  rc=$(run_case recovers "${case_dir}" 1800)
  assert_status "${rc}" 0 "readiness wait that recovers on the second poll"
  assert_contains "${case_dir}/output.log" "WAITING: all pods ready in ${HCP_NAMESPACE}"
  assert_contains "${case_dir}/output.log" "retrying in 60s"
  # Exactly one 60 second wait: a changed poll interval must fail here rather
  # than pass on a substring of the log line.
  [[ "$(cat "${case_dir}/state/sleep-delays")" == "60" ]] || \
    fail "expected a single 60s poll interval, got '$(cat "${case_dir}/state/sleep-delays")'"
  [[ "$(cat "${case_dir}/state/pod-list-attempts")" == "2" ]] || fail "expected exactly two pod list polls"
  assert_no_artifact "${case_dir}"
}

test_timeout_captures_diagnostics_and_preserves_failure() {
  local case_dir="${TEST_ROOT}/timeout" rc artifact
  rc=$(run_case timeout "${case_dir}")
  assert_status "${rc}" 1 "readiness wait that times out"
  assert_contains "${case_dir}/output.log" "ERROR: Timed out after 0s waiting for: all pods ready in ${HCP_NAMESPACE}"
  # The original failure outcome is preserved: the step stops at the pod wait
  # and never reports the later checks as passed.
  assert_not_contains "${case_dir}/output.log" "PASSED: all pods ready"
  assert_not_contains "${case_dir}/output.log" "VpcEndpoint"
  assert_not_contains "${case_dir}/output.log" "All HostedControlPlane readiness checks passed"

  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.schemaVersion' '1'
  assert_json "${artifact}" '.kind' 'ROSAHCPPodDiagnostics'
  assert_json "${artifact}" '.trigger' 'pod-readiness-wait-failed'
  assert_json "${artifact}" '.collection.pods.status' 'ok'
  assert_json "${artifact}" '.collection.events.status' 'ok'
  assert_json "${artifact}" '.collection.pods.observed' '2'
  assert_json "${artifact}" '.collection.pods.reported' '2'
  assert_json "${artifact}" '.collection.pods.unparsableItems' '2'
  assert_json "${artifact}" '.lastPoll.podQuery' 'succeeded'
  assert_json "${artifact}" '.lastPoll.podCount' '12'
  assert_json "${artifact}" '.lastPoll.podCountBelowMinimum' 'false'
  assert_json "${artifact}" '.minimumExpectedPods' '10'
  assert_json "${artifact}" '.waitTimeoutSeconds' '0'
  assert_json "${artifact}" '.waitElapsedSeconds | type' 'number'
  assert_json "${artifact}" '.waitElapsedSeconds >= 0' 'true'
  assert_json "${artifact}" '.summary.podsNotReady' '1'
  assert_json "${artifact}" '.summary.podsByPhase | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")' 'Pending=1,Running=1'
  assert_json "${artifact}" '.collection.events.observedPodEvents' '5'
  assert_json "${artifact}" '.collection.events.reportedGroups' '4'
  assert_json "${artifact}" '.notes | sort | join(",")' 'pod-items-unparsable'

  # Timestamps survive the sanitizer rather than being dropped wholesale.
  assert_json "${artifact}" '.pods[0].creationTimestamp' '2026-11-25T10:00:00Z'
  assert_json "${artifact}" '.pods[0].startTime' '2026-11-25T10:00:05Z'
  assert_json "${artifact}" '.pods[0].conditions[0].lastTransitionTime' '2026-11-25T10:00:06Z'

  # Run-local aliases only, assigned in UID sort order.
  assert_json "${artifact}" '[.pods[].alias] | join(",")' 'pod-001,pod-002'

  # Conditions, container categories and restart counters for the unready pod.
  assert_json "${artifact}" '.pods[0].phase' 'Pending'
  assert_json "${artifact}" '[.pods[0].conditions[].type] | join(",")' 'PodScheduled,Ready'
  assert_json "${artifact}" '[.pods[0].conditions[].reason] | join(",")' 'Unschedulable,ContainersNotReady'
  assert_json "${artifact}" '.pods[0].containers.total' '2'
  assert_json "${artifact}" '.pods[0].containers.ready' '0'
  assert_json "${artifact}" '.pods[0].containers.restartsTotal' '9'
  assert_json "${artifact}" '.pods[0].containers.restartsMax' '7'
  assert_json "${artifact}" '.pods[0].containers.byState.waiting' '2'
  assert_json "${artifact}" '.pods[0].containers.waitingReasons.CrashLoopBackOff' '1'
  assert_json "${artifact}" '.pods[0].initContainers.terminatedReasons.Completed' '1'

  # Events are correlated to the pod through its UID, aggregated by
  # type and reason, and carry no UID or message of their own.
  assert_json "${artifact}" '[.pods[0].events[] | .reason] | sort | join(",")' 'BackOff,FailedScheduling,Other'
  assert_json "${artifact}" '[.pods[0].events[] | select(.reason=="BackOff") | .count] | add' '12'
  assert_json "${artifact}" '[.pods[0].events[] | has("uid")] | any' 'false'
  # Two FailedScheduling events merge into one group: counts add, and the
  # window spans the earliest first and the latest last timestamp.
  assert_json "${artifact}" '.pods[0].events[] | select(.reason=="FailedScheduling") | .count' '5'
  assert_json "${artifact}" '.pods[0].events[] | select(.reason=="FailedScheduling") | .firstTimestamp' '2026-11-25T10:00:10Z'
  assert_json "${artifact}" '.pods[0].events[] | select(.reason=="FailedScheduling") | .lastTimestamp' '2026-11-25T10:05:10Z'
  # Highest-count group first, so a truncated list keeps the loudest signal.
  assert_json "${artifact}" '.pods[0].events[0].reason' 'BackOff'
  assert_json "${artifact}" '[.. | objects | has("message")] | any' 'false'
  assert_json "${artifact}" '.unmatchedPodEvents | length' '1'
  assert_json "${artifact}" '.unmatchedPodEvents[0].reason' 'Killing'
  assert_json "${artifact}" '[.unmatchedPodEvents[] | has("uid")] | any' 'false'

  # Unknown condition types are dropped; unknown enum values become "Other".
  assert_json "${artifact}" '[.pods[0].conditions[].type] | index("SomeUnknownFutureCondition") // "absent"' 'absent'
  assert_json "${artifact}" '.pods[0].containers.waitingReasons.Other' '1'

  # Collection stays inside the HCP namespace the readiness checks already
  # use, and both queries are bounded.
  assert_contains "${case_dir}/state/oc-invocations" "get pods -n ${HCP_NAMESPACE} -o json --request-timeout=60s"
  assert_contains "${case_dir}/state/oc-invocations" "get events -n ${HCP_NAMESPACE} -o json --request-timeout=60s"
  [[ "$(grep -c -- '-o json --request-timeout=60s' "${case_dir}/state/oc-invocations")" == "2" ]] || \
    fail "expected exactly one pod and one event collection query"
  # grep -v consumes all of its input, so this cannot SIGPIPE under pipefail.
  if grep -- '--request-timeout=60s' "${case_dir}/state/oc-invocations" \
     | grep -v -- "-n ${HCP_NAMESPACE} " > /dev/null; then
    fail "a collection query left the HCP namespace"
  fi

  assert_no_sensitive_values "${artifact}"
  assert_not_contains "${artifact}" "${HCP_NAMESPACE}"
  assert_not_contains "${artifact}" "${CLUSTER_ID}"
  assert_not_contains "${artifact}" "${CLUSTER_NAME}"
  assert_artifact_vocabulary "${artifact}"
  assert_artifact_dir_holds_only_the_artifact "${case_dir}"
  assert_no_credentials "${case_dir}/output.log"
}

test_scratch_space_stays_out_of_the_artifact_dir() {
  local case_dir="${TEST_ROOT}/tmpdir-in-artifacts" rc artifact
  rc=$(run_case tmpdir_in_artifact_dir "${case_dir}")
  assert_status "${rc}" 1 "readiness wait with TMPDIR pointed at ARTIFACT_DIR"
  artifact=$(artifact_path "${case_dir}")
  # Collection still succeeded, so the scratch directory was relocated rather
  # than skipped.
  assert_json "${artifact}" '.collection.pods.status' 'ok'
  assert_json "${artifact}" '.collection.events.status' 'ok'
  assert_json "${artifact}" '.pods | length' '2'
  assert_artifact_dir_holds_only_the_artifact "${case_dir}"
  assert_scratch_files_were_outside_the_artifact_dir "${case_dir}"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_pod_query_error_is_reported_separately() {
  local case_dir="${TEST_ROOT}/pod-query-error" rc artifact
  rc=$(run_case pod_list_error "${case_dir}")
  assert_status "${rc}" 1 "readiness wait with a failing pod query"
  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.lastPoll.podQuery' 'failed'
  assert_json "${artifact}" '.lastPoll.podCount' '0'
  assert_json "${artifact}" '.collection.pods.status' 'unavailable'
  assert_json "${artifact}" '.collection.pods.observed' '0'
  assert_json "${artifact}" '.pods | length' '0'
  assert_json "${artifact}" '.notes | sort | join(",")' 'last-poll-pod-query-failed,pod-collection-unavailable'
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: pod collection unavailable"
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: last readiness poll pod query failed"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_invalid_responses_are_reported_as_malformed() {
  local case_dir="${TEST_ROOT}/malformed" rc artifact
  rc=$(run_case pod_json_malformed "${case_dir}")
  assert_status "${rc}" 1 "readiness wait with malformed collection responses"
  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.collection.pods.status' 'malformed'
  assert_json "${artifact}" '.collection.events.status' 'malformed'
  assert_json "${artifact}" '.pods | length' '0'
  assert_json "${artifact}" '.unmatchedPodEvents | length' '0'
  assert_json "${artifact}" '.lastPoll.podQuery' 'succeeded'
  assert_json "${artifact}" '.notes | sort | join(",")' 'event-collection-malformed,pod-collection-malformed'
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: pod collection malformed"
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: event collection malformed"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_event_collection_failure_does_not_lose_pod_diagnostics() {
  local case_dir="${TEST_ROOT}/event-error" rc artifact
  rc=$(run_case event_json_error "${case_dir}")
  assert_status "${rc}" 1 "readiness wait with a failing event query"
  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.collection.pods.status' 'ok'
  assert_json "${artifact}" '.collection.events.status' 'unavailable'
  assert_json "${artifact}" '.pods | length' '2'
  assert_json "${artifact}" '[.pods[].events | length] | add' '0'
  assert_json "${artifact}" '.notes | sort | join(",")' 'event-collection-unavailable,pod-items-unparsable'
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: event collection unavailable"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_too_few_pods_is_reported_separately() {
  local case_dir="${TEST_ROOT}/too-few" rc artifact
  rc=$(run_case too_few_pods "${case_dir}")
  assert_status "${rc}" 1 "readiness wait that never saw enough pods"
  assert_contains "${case_dir}/output.log" "Too few pods found, expected at least 10"
  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.lastPoll.podCount' '3'
  assert_json "${artifact}" '.lastPoll.podCountBelowMinimum' 'true'
  assert_json "${artifact}" '.lastPoll.podQuery' 'succeeded'
  assert_json "${artifact}" '.notes | index("last-poll-pod-count-below-minimum") != null' 'true'
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: last readiness poll counted 3 pods, below the minimum of 10"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_missing_artifact_dir_does_not_change_the_outcome() {
  local case_dir="${TEST_ROOT}/no-artifact-dir" rc
  rc=$(run_case timeout "${case_dir}" 0 false)
  assert_status "${rc}" 1 "readiness wait without ARTIFACT_DIR"
  assert_contains "${case_dir}/output.log" "Skipping HCP pod diagnostics: ARTIFACT_DIR is not set"
  assert_no_artifact "${case_dir}"
  assert_no_credentials "${case_dir}/output.log"
}

test_unwritable_artifact_dir_does_not_change_the_outcome() {
  local case_dir="${TEST_ROOT}/readonly-artifact-dir" rc
  if [[ "${EUID}" == "0" ]]; then
    echo "WARNING: skipping unwritable ARTIFACT_DIR case: running as root bypasses directory permissions"
    return 0
  fi
  rc=$(run_case artifact_dir_readonly "${case_dir}")
  assert_status "${rc}" 1 "readiness wait with a read-only ARTIFACT_DIR"
  assert_contains "${case_dir}/output.log" "Skipping HCP pod diagnostics: ARTIFACT_DIR is not writable"
  assert_not_contains "${case_dir}/output.log" "Permission denied"
  assert_not_contains "${case_dir}/output.log" "Wrote sanitized HCP pod diagnostics"
  assert_no_artifact "${case_dir}"
}

test_oversized_response_is_rejected_on_size() {
  local case_dir="${TEST_ROOT}/oversized" rc artifact
  rc=$(run_case pod_json_oversized "${case_dir}")
  assert_status "${rc}" 1 "readiness wait with an oversized pod response"
  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.collection.pods.status' 'oversized'
  assert_json "${artifact}" '.pods | length' '0'
  assert_json "${artifact}" '.notes | index("pod-collection-oversized") != null' 'true'
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: pod collection oversized"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_rendering_failure_still_writes_a_parseable_artifact() {
  local case_dir="${TEST_ROOT}/render-failure" rc artifact
  rc=$(run_case render_failure "${case_dir}")
  assert_status "${rc}" 1 "readiness wait where the artifact renderer fails"
  artifact=$(artifact_path "${case_dir}")
  assert_valid_json "${artifact}"
  assert_json "${artifact}" '.kind' 'ROSAHCPPodDiagnostics'
  assert_json "${artifact}" '.trigger' 'pod-readiness-wait-failed'
  assert_json "${artifact}" '.notes | join(",")' 'diagnostics-rendering-failed'
  assert_json "${artifact}" '.pods | length' '0'
  assert_json "${artifact}" '.lastPoll.podQuery' 'succeeded'
  assert_json "${artifact}" '.lastPoll.podCount' '12'
  assert_json "${artifact}" '.lastPoll.podCountBelowMinimum' 'false'
  assert_contains "${case_dir}/output.log" "HCP pod diagnostics: rendering failed, wrote a status-only artifact"
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_last_poll_fields_describe_the_final_poll() {
  local case_dir="${TEST_ROOT}/last-poll-wins" rc artifact
  # A faked epoch makes the deadline deterministic: poll 1 at +30s, poll 2 at
  # +60s, which is past the 45s budget.
  rc=$(run_case last_poll_wins "${case_dir}" 45)
  assert_status "${rc}" 1 "readiness wait whose final poll fails outright"
  [[ "$(cat "${case_dir}/state/pod-list-attempts")" == "2" ]] || fail "expected exactly two pod list polls"
  artifact=$(artifact_path "${case_dir}")
  assert_json "${artifact}" '.waitTimeoutSeconds' '45'
  assert_json "${artifact}" '.waitElapsedSeconds' '90'
  # The first poll saw three pods; the reported state must be the second one.
  assert_json "${artifact}" '.lastPoll.podQuery' 'failed'
  assert_json "${artifact}" '.lastPoll.podCount' '0'
  assert_json "${artifact}" '.lastPoll.podCountBelowMinimum' 'false'
  assert_json "${artifact}" '.notes | index("last-poll-pod-count-below-minimum") // "absent"' 'absent'
  assert_json "${artifact}" '.notes | index("last-poll-pod-query-failed") != null' 'true'
  assert_no_sensitive_values "${artifact}"
  assert_artifact_vocabulary "${artifact}"
}

test_ref_declares_wait_contract
test_allowlists_match_the_command_script
test_successful_wait_is_unchanged
test_poll_behavior_and_shared_deadline_are_unchanged
test_timeout_captures_diagnostics_and_preserves_failure
test_scratch_space_stays_out_of_the_artifact_dir
test_pod_query_error_is_reported_separately
test_invalid_responses_are_reported_as_malformed
test_event_collection_failure_does_not_lose_pod_diagnostics
test_too_few_pods_is_reported_separately
test_missing_artifact_dir_does_not_change_the_outcome
test_unwritable_artifact_dir_does_not_change_the_outcome
test_oversized_response_is_rejected_on_size
test_rendering_failure_still_writes_a_parseable_artifact
test_last_poll_fields_describe_the_final_poll

echo "PASS: rosa hosted control plane readiness diagnostics tests"
