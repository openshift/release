#!/bin/bash
# Offline tests for the ocm-backplane CLI acquisition in the
# rosa-gather-hcp-cr-status step. No network, no cluster, no credentials.
# Run locally with: bash hack/test-rosa-gather-hcp-cr-status.sh
set -euo pipefail

step_dir="$(dirname "$0")/../ci-operator/step-registry/rosa/gather/hcp-cr-status"
script="${step_dir}/rosa-gather-hcp-cr-status-commands.sh"

if [[ "${1:-}" != --case ]]; then
  logs="$(mktemp -d)"
  for scenario in success-first-attempt retry-504-then-success exhausted-504 \
    retry-timeout-then-success no-retry-404 no-retry-403 no-retry-401 \
    transient-classification no-budget-no-attempt budget-exhausted \
    max-time-tracks-remaining-budget total-elapsed-within-budget \
    interrupted-sleep term-during-backoff-does-not-hang \
    malformed-archive binary-missing-from-archive partial-cleanup \
    no-leak-under-xtrace real-script-no-cluster-id \
    real-script-download-failure-exits-zero; do
    result=0
    bash "$0" --case "$scenario" > "$logs/$scenario.log" 2>&1 || result=$?
    if [[ "$result" != 0 ]]; then
      printf 'FAIL: %s (exit %s); log: %s\n' "$scenario" "$result" "$logs/$scenario.log" >&2
      exit 1
    fi
    printf 'PASS: %s\n' "$scenario"
  done
  printf 'Fixture logs: %s\n' "$logs"
  exit
fi

scenario="$2"
test_dir="$(mktemp -d)"
# Clear the fixtures when the scenario passes, so a full run does not leave a
# directory per scenario behind, and keep them when it fails, where the
# tarballs, logs and status file are the evidence. Name the retained path:
# the outer runner reports where the captured output went, not the fixtures.
# This is an EXIT trap; the TERM trap the sourced step installs is separate
# and must keep working for the signal scenario.
trap 'rc=$?;
  if (( rc == 0 )); then
    rm -rf "$test_dir"
  else
    printf "fixtures retained: %s\n" "$test_dir" >&2
  fi
  exit $rc' EXIT
export ARTIFACT_DIR="$test_dir/artifacts"
export SHARED_DIR="$test_dir/shared"
export OCM_LOGIN_ENV=integration
CR_DIR="$ARTIFACT_DIR/cr-status"
status_file="$CR_DIR/backplane-cli-download.txt"
bin_dir="$test_dir/bin"
mkdir -p "$CR_DIR" "$SHARED_DIR" "$bin_dir"

fail() {
  printf 'FAIL(%s): %s\n' "$scenario" "$*" >&2
  exit 1
}

assert_status() {
  local key="$1" want="$2" got
  got="$(sed -n "s/^${key}=//p" "$status_file")"
  [[ "$got" == "$want" ]] || fail "expected ${key}=${want}, got ${key}=${got:-<missing>}"
}

# ---- scenarios that run the real script end to end --------------------------

# The step is best_effort: it must exit 0 even when it collects nothing.
if [[ "$scenario" == real-script-no-cluster-id ]]; then
  rc=0
  bash "$script" > "$test_dir/run.log" 2>&1 || rc=$?
  [[ "$rc" == 0 ]] || fail "step exited ${rc}, best_effort requires 0"
  grep -q 'No cluster-id found' "$test_dir/run.log" || fail 'missing skip message'
  exit 0
fi

# A failed CLI acquisition must still leave the step exiting 0, must still log
# the original operator-facing error, and must leave the sanitized record
# behind. A zero budget fails the download without touching the network.
if [[ "$scenario" == real-script-download-failure-exits-zero ]]; then
  echo 'cluster-abc' > "$SHARED_DIR/cluster-id"
  rc=0
  BP_DOWNLOAD_BUDGET_SECONDS=0 bash "$script" > "$test_dir/run.log" 2>&1 || rc=$?
  [[ "$rc" == 0 ]] || fail "step exited ${rc}, best_effort requires 0"
  grep -q 'ERROR: Failed to download ocm-backplane CLI' "$test_dir/run.log" \
    || fail 'original download failure message was lost'
  assert_status result failure
  assert_status reason budget_exhausted
  assert_status attempts 0
  exit 0
fi

# ---- unit scenarios over the real acquisition functions ---------------------

export BP_DOWNLOAD_MAX_ATTEMPTS=3
export BP_DOWNLOAD_RETRY_BASE_DELAY=5
export BP_DOWNLOAD_RETRY_MAX_DELAY=30
case "$scenario" in
  no-budget-no-attempt) export BP_DOWNLOAD_BUDGET_SECONDS=0 ;;
  budget-exhausted) export BP_DOWNLOAD_BUDGET_SECONDS=100 ;;
  # Production-like: the whole budget and the real attempt ceiling, so the
  # elapsed accounting is checked against the limits the step actually ships.
  total-elapsed-within-budget)
    export BP_DOWNLOAD_BUDGET_SECONDS=300 BP_DOWNLOAD_MAX_ATTEMPTS=4 ;;
  *) export BP_DOWNLOAD_BUDGET_SECONDS=300 ;;
esac

# Test the real functions, without the cluster-facing part of the step.
# shellcheck disable=SC1090
source <(sed -n '1,/^# ---- end of sourceable definitions/p' "$script")

# The retry decision is the whole point of the change, so check the table
# directly rather than inferring it from the two statuses the flow happens to
# exercise.
if [[ "$scenario" == transient-classification ]]; then
  for probe in 408 425 429 500 502 503 504; do
    if ! bp_download_is_transient "$probe" 22; then
      fail "HTTP ${probe} must be retried"
    fi
  done
  for probe in 6 7 16 18 28 35 52 55 56; do
    if ! bp_download_is_transient 000 "$probe"; then
      fail "curl exit ${probe} must be retried"
    fi
  done
  for probe in 400 401 403 404 405 410 451; do
    if bp_download_is_transient "$probe" 22; then
      fail "HTTP ${probe} is a settled answer and must not be retried"
    fi
  done
  for probe in 1 3 22 23 27 60 63 77; do
    if bp_download_is_transient 000 "$probe"; then
      fail "curl exit ${probe} is not transient and must not be retried"
    fi
  done
  exit 0
fi

# A real SIGTERM during backoff must be acted on at once. A foreground sleep
# would defer the step's TERM handler for the whole delay, outlasting the
# grace period the ref declares, so this runs the actual script in a child
# process and signals it for real rather than mocking the sleep away.
if [[ "$scenario" == term-during-backoff-does-not-hang ]]; then
  marker="$test_dir/child-ready"
  child="$test_dir/child.sh"
  cat > "$child" <<'CHILD'
#!/bin/bash
source <(sed -n '1,/^# ---- end of sourceable definitions/p' "$1")
curl() {
  local arg prev='' output=''
  for arg in "$@"; do
    if [[ "$prev" == -o ]]; then output="$arg"; fi
    prev="$arg"
  done
  printf 'partial-body' > "$output"
  echo 504
  return 22
}
echo ready > "$2"
install_backplane_cli 0.12.0 "$3" "$4"
CHILD

  # The child uses the real mktemp, so record what /tmp held beforehand to
  # tell a leaked working directory from unrelated ones.
  before_dirs="$test_dir/tmp-before"
  find /tmp -maxdepth 1 -name 'backplane-download.*' -print 2>/dev/null | sort > "$before_dirs"
  BP_DOWNLOAD_RETRY_BASE_DELAY=20 BP_DOWNLOAD_RETRY_MAX_DELAY=20 \
    bash "$child" "$script" "$marker" "$bin_dir" "$CR_DIR" > "$test_dir/child.log" 2>&1 &
  child_pid=$!
  for _ in $(seq 1 100); do
    [[ -s "$marker" ]] && break
    sleep 0.1
  done
  [[ -s "$marker" ]] || fail 'the child step never started'
  # Let it settle into the 20s backoff before signalling.
  sleep 2

  signalled="$(date +%s)"
  kill -TERM "$child_pid"
  ( sleep 10; kill -KILL "$child_pid" 2>/dev/null ) &
  killer=$!
  wait "$child_pid" || true
  reaction=$(( $(date +%s) - signalled ))
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true

  (( reaction < 10 )) \
    || fail "the step hung ${reaction}s after TERM instead of unwinding the backoff"
  assert_status result failure
  assert_status reason interrupted
  assert_status attempts 1
  assert_status retries 0
  after_dirs="$test_dir/tmp-after"
  find /tmp -maxdepth 1 -name 'backplane-download.*' -print 2>/dev/null | sort > "$after_dirs"
  leftovers="$(comm -13 "$before_dirs" "$after_dirs")"
  [[ -z "$leftovers" ]] || fail "signal path left a working directory behind: ${leftovers}"
  [[ ! -e "$bin_dir/ocm-backplane" ]] || fail 'interrupted acquisition left a binary behind'
  exit 0
fi

# Archive fixtures: one good release tarball, one that is not gzip at all, and
# one that is valid but does not carry the binary.
mkdir -p "$test_dir/payload"
printf '#!/bin/sh\necho ocm-backplane fixture\n' > "$test_dir/payload/ocm-backplane"
chmod 0755 "$test_dir/payload/ocm-backplane"
printf 'LICENSE text\n' > "$test_dir/payload/LICENSE"
tar -czf "$test_dir/good.tar.gz" -C "$test_dir/payload" ocm-backplane LICENSE
tar -czf "$test_dir/no-binary.tar.gz" -C "$test_dir/payload" LICENSE

# Keep every temporary file the step creates inside the fixture directory, so
# leftovers are observable instead of scattered through /tmp.
mktemp() {
  if [[ "${1:-}" == -d ]]; then
    command mktemp -d "$test_dir/work.XXXXXX"
  else
    command mktemp "$test_dir/file.XXXXXX"
  fi
}

# A fake clock so budget and backoff are exercised without real waiting. The
# step reads the download status through a command substitution, so the mocks
# run in a subshell: keep their state in files, not in variables.
clock_file="$test_dir/clock"
calls_file="$test_dir/curl-calls"
max_times_file="$test_dir/max-times"
echo 1000 > "$clock_file"
: > "$max_times_file"
echo 0 > "$calls_file"
attempt_seconds=1

advance_clock() {
  echo $(( $(cat "$clock_file") + $1 )) > "$clock_file"
}
curl_calls() {
  cat "$calls_file"
}
bp_now() {
  cat "$clock_file"
}
bp_sleep() {
  # A sleep that returns non-zero models the step being signalled mid-backoff.
  if [[ "$scenario" == interrupted-sleep ]]; then
    return 130
  fi
  advance_clock "$1"
  return 0
}

case "$scenario" in
  budget-exhausted) attempt_seconds=60 ;;
  max-time-tracks-remaining-budget) attempt_seconds=30 ;;
  total-elapsed-within-budget) attempt_seconds=90 ;;
esac

if [[ "$scenario" == no-leak-under-xtrace ]]; then
  export https_proxy='http://proxyuser:proxypassword@squid.example.invalid:3128'
  export HTTPS_PROXY="$https_proxy"
fi

curl() {
  local arg prev='' output='' max_time='' calls
  for arg in "$@"; do
    case "$prev" in
      -o) output="$arg" ;;
      --max-time) max_time="$arg" ;;
    esac
    prev="$arg"
  done
  if [[ -z "$output" ]]; then
    echo 'curl was called without an output file' > "$test_dir/mock-error"
    return 99
  fi
  if [[ -z "$max_time" ]]; then
    echo 'curl was called without --max-time' > "$test_dir/mock-error"
    return 99
  fi
  # Record the per-attempt ceiling so the budget guarantee can be asserted.
  echo "$max_time" >> "$max_times_file"
  calls=$(( $(cat "$calls_file") + 1 ))
  echo "$calls" > "$calls_file"
  # Real curl gives up at --max-time, so an attempt can never burn more than
  # the budget it was handed. A mock that ignored this would let the step
  # appear to overrun a limit that curl actually enforces.
  if (( attempt_seconds > max_time )); then
    advance_clock "$max_time"
  else
    advance_clock "$attempt_seconds"
  fi

  # Real curl leaves whatever arrived before the failure on disk; reproduce it
  # so partial-body cleanup is genuinely exercised.
  partial() {
    printf 'not-a-complete-gzip-body' > "$output"
  }
  # A complete, well-formed release tarball.
  complete_body() {
    cp "$test_dir/good.tar.gz" "$output"
  }
  # Real curl reports transport errors on stderr, quoting the URL and the
  # proxy. The step must swallow that text.
  noisy_stderr() {
    echo "curl: (56) Recv failure: https://objects.example.invalid/ocm-backplane.tar.gz?X-Amz-Signature=SECRETSIGNATURE via ${https_proxy:-none}" >&2
  }

  case "$scenario" in
    success-first-attempt)
      complete_body; echo 200; return 0 ;;
    retry-504-then-success)
      if (( calls == 1 )); then partial; echo 504; return 22; fi
      complete_body; echo 200; return 0 ;;
    retry-timeout-then-success)
      if (( calls == 1 )); then partial; echo 000; return 28; fi
      complete_body; echo 200; return 0 ;;
    exhausted-504|partial-cleanup|budget-exhausted|interrupted-sleep|max-time-tracks-remaining-budget|total-elapsed-within-budget)
      partial; echo 504; return 22 ;;
    no-leak-under-xtrace)
      partial; noisy_stderr; echo 504; return 22 ;;
    no-retry-404)
      echo 404; return 22 ;;
    no-retry-403)
      echo 403; return 22 ;;
    no-retry-401)
      echo 401; return 22 ;;
    malformed-archive)
      printf 'this is not a gzip archive' > "$output"; echo 200; return 0 ;;
    binary-missing-from-archive)
      cp "$test_dir/no-binary.tar.gz" "$output"; echo 200; return 0 ;;
    *)
      echo "no curl behaviour defined for ${scenario}" > "$test_dir/mock-error"
      return 99 ;;
  esac
}

rc=0
if [[ "$scenario" == no-leak-under-xtrace ]]; then
  # Capture everything the step emits while xtrace is on.
  set -x
  install_backplane_cli 0.12.0 "$bin_dir" "$CR_DIR" > "$test_dir/traced.log" 2>&1 || rc=$?
  set +x
else
  install_backplane_cli 0.12.0 "$bin_dir" "$CR_DIR" > "$test_dir/step.log" 2>&1 || rc=$?
fi

if [[ -f "$test_dir/mock-error" ]]; then
  fail "$(cat "$test_dir/mock-error")"
fi

# Nothing may be left behind in the working area on any path.
leftovers="$(find "$test_dir" -maxdepth 1 -name 'work.*' -print)"
[[ -z "$leftovers" ]] || fail "working directory was not cleaned up: ${leftovers}"

case "$scenario" in
  success-first-attempt)
    [[ "$rc" == 0 ]] || fail "expected success, got exit ${rc}"
    [[ -x "$bin_dir/ocm-backplane" ]] || fail 'binary was not promoted'
    [[ "$(curl_calls)" == 1 ]] || fail "expected 1 request, made $(curl_calls)"
    assert_status result success
    assert_status reason ok
    assert_status attempts 1
    assert_status retries 0
    assert_status http_status 200
    assert_status curl_exit 0
    ;;
  retry-504-then-success|retry-timeout-then-success)
    [[ "$rc" == 0 ]] || fail "expected recovery, got exit ${rc}"
    [[ -x "$bin_dir/ocm-backplane" ]] || fail 'binary was not promoted after retry'
    [[ "$(curl_calls)" == 2 ]] || fail "expected 2 requests, made $(curl_calls)"
    assert_status result success
    assert_status attempts 2
    assert_status retries 1
    ;;
  exhausted-504|partial-cleanup)
    [[ "$rc" != 0 ]] || fail 'repeated 504 must not report success'
    [[ ! -e "$bin_dir/ocm-backplane" ]] || fail 'failed acquisition left a binary behind'
    [[ "$(curl_calls)" == "$BP_DOWNLOAD_MAX_ATTEMPTS" ]] \
      || fail "expected ${BP_DOWNLOAD_MAX_ATTEMPTS} requests, made $(curl_calls)"
    assert_status result failure
    assert_status reason attempts_exhausted
    assert_status attempts "$BP_DOWNLOAD_MAX_ATTEMPTS"
    assert_status http_status 504
    ;;
  no-retry-404|no-retry-403|no-retry-401)
    [[ "$rc" != 0 ]] || fail 'a permanent status must not report success'
    [[ "$(curl_calls)" == 1 ]] || fail "a permanent status was retried: $(curl_calls) requests"
    [[ ! -e "$bin_dir/ocm-backplane" ]] || fail 'failed acquisition left a binary behind'
    assert_status result failure
    assert_status reason not_retriable
    assert_status attempts 1
    assert_status http_status "${scenario##*-}"
    ;;
  no-budget-no-attempt)
    [[ "$rc" != 0 ]] || fail 'an exhausted budget must not report success'
    [[ "$(curl_calls)" == 0 ]] || fail 'a request was made with no budget left'
    assert_status result failure
    assert_status reason budget_exhausted
    assert_status attempts 0
    ;;
  max-time-tracks-remaining-budget)
    [[ "$rc" != 0 ]] || fail 'repeated 504 must not report success'
    mapfile -t max_times < "$max_times_file"
    (( ${#max_times[@]} >= 2 )) || fail 'too few attempts to compare per-attempt budgets'
    [[ "${max_times[0]}" == "$BP_DOWNLOAD_BUDGET_SECONDS" ]] \
      || fail "first attempt should get the whole budget, got ${max_times[0]}"
    previous=''
    for observed in "${max_times[@]}"; do
      (( observed > 0 )) || fail "an attempt ran with a non-positive budget: ${observed}"
      (( observed <= BP_DOWNLOAD_BUDGET_SECONDS )) \
        || fail "attempt budget ${observed} exceeds the total ${BP_DOWNLOAD_BUDGET_SECONDS}"
      if [[ -n "$previous" ]]; then
        (( observed < previous )) \
          || fail "per-attempt budget did not shrink: ${previous} then ${observed}"
      fi
      previous="$observed"
    done
    ;;
  total-elapsed-within-budget)
    [[ "$rc" != 0 ]] || fail 'repeated 504 must not report success'
    # Network time and backoff both come out of the one budget.
    elapsed="$(sed -n 's/^elapsed_seconds=//p' "$status_file")"
    (( elapsed <= BP_DOWNLOAD_BUDGET_SECONDS )) \
      || fail "elapsed ${elapsed}s exceeded the ${BP_DOWNLOAD_BUDGET_SECONDS}s budget"
    (( $(sed -n 's/^retries=//p' "$status_file") >= 2 )) \
      || fail 'expected the run to include backoff sleeps'
    (( elapsed >= 180 )) || fail "expected a long run, got ${elapsed}s"
    ;;
  budget-exhausted)
    [[ "$rc" != 0 ]] || fail 'an exhausted budget must not report success'
    (( $(curl_calls) < BP_DOWNLOAD_MAX_ATTEMPTS )) \
      || fail "budget did not stop the retries: $(curl_calls) requests"
    assert_status result failure
    assert_status reason budget_exhausted
    ;;
  interrupted-sleep)
    [[ "$rc" != 0 ]] || fail 'an interrupted backoff must not report success'
    [[ "$(curl_calls)" == 1 ]] || fail "expected 1 request, made $(curl_calls)"
    assert_status result failure
    assert_status reason interrupted
    assert_status retries 0
    ;;
  malformed-archive)
    [[ "$rc" != 0 ]] || fail 'an unreadable archive must not report success'
    [[ "$(curl_calls)" == 1 ]] || fail "an archive failure was retried: $(curl_calls) requests"
    [[ ! -e "$bin_dir/ocm-backplane" ]] || fail 'a bad archive produced a binary'
    assert_status result failure
    assert_status reason archive_unreadable
    ;;
  binary-missing-from-archive)
    [[ "$rc" != 0 ]] || fail 'an archive without the binary must not report success'
    [[ ! -e "$bin_dir/ocm-backplane" ]] || fail 'binary appeared from an archive without one'
    assert_status result failure
    assert_status reason binary_missing
    ;;
  no-leak-under-xtrace)
    [[ "$rc" != 0 ]] || fail 'expected the download to fail in this scenario'
    for secret in proxypassword SECRETSIGNATURE X-Amz-Signature \
      objects.example.invalid 'Recv failure'; do
      if grep -qF "$secret" "$test_dir/traced.log"; then
        fail "traced output leaked '${secret}'"
      fi
    done
    ;;
esac

# No run may ever report spending more than the whole budget.
if [[ -f "$status_file" ]]; then
  recorded_elapsed="$(sed -n 's/^elapsed_seconds=//p' "$status_file")"
  (( recorded_elapsed <= BP_DOWNLOAD_BUDGET_SECONDS )) \
    || fail "recorded elapsed ${recorded_elapsed}s exceeds the budget"
fi

# The artifact is a fixed-field record: no URLs, no proxy, no transport text.
if [[ -f "$status_file" ]]; then
  if grep -qE '://|Signature|proxy' "$status_file"; then
    fail 'download artifact carries a URL, a signature or a proxy value'
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^[a-z_]+=[A-Za-z0-9_]*$ ]] \
      || fail "download artifact has a non-fixed-field line: ${line}"
  done < "$status_file"
fi
