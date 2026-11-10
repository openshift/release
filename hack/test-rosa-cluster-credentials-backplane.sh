#!/bin/bash
# Offline regression test for the ocm-backplane CLI download in
# ci-operator/step-registry/rosa/cluster/credentials/backplane.
# Run locally with: bash hack/test-rosa-cluster-credentials-backplane.sh
#
# The whole step runs against stubbed curl/tar/ocm/ocm-backplane/oc/sleep/date
# binaries, so the cases are deterministic and never touch the network, OCM or a
# cluster.
set -euo pipefail

script="$(dirname "$0")/../ci-operator/step-registry/rosa/cluster/credentials/backplane/rosa-cluster-credentials-backplane-commands.sh"
test_dir="$(mktemp -d)"
# The step creates /tmp/backplane-bin.XXXXXX itself; drop the ones this run made.
cleanup() {
    find /tmp -maxdepth 1 -name 'backplane-bin.*' -newer "$test_dir/started" -exec rm -rf {} + 2>/dev/null || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
touch "$test_dir/started"

# Sentinels that must never reach the step log or the download diagnostics.
client_id_sentinel="sso-client-id-SENTINEL"
client_secret_sentinel="sso-client-secret-SENTINEL"
cluster_id_sentinel="clusteridSENTINEL000000000000000"
# An invalid BACKPLANE_DOWNLOAD_RETRIES override must never be echoed back.
override_sentinel="RETRIESSENTINEL"
pinned_url_path="releases/download/v0.12.0/ocm-backplane_0.12.0_Linux_x86_64.tar.gz"

stub_dir="$test_dir/bin"
mkdir -p "$stub_dir"

cat >"$stub_dir/curl" <<'STUB'
#!/bin/bash
# Deterministic curl: one "<http_code> <curl_exit> <body>" plan line per attempt.
# The last line repeats so exhaustion cases need a single line, but a runaway
# loop must surface rather than spin.
set -u
out=""; prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out="$arg"
  prev="$arg"
done
n=$(( $(cat "$CASE_DIR/curl-count") + 1 ))
printf '%s\n' "$n" >"$CASE_DIR/curl-count"
printf '%s\n' "$*" >>"$CASE_DIR/curl-args"
if [[ "$n" -gt 20 ]]; then
  printf 'stub curl: more than 20 attempts, download loop is not bounded\n' >&2
  exit 99
fi
plan="$(sed -n "${n}p" "$CASE_DIR/curl-plan")"
[[ -z "$plan" ]] && plan="$(tail -n 1 "$CASE_DIR/curl-plan")"
read -r code rc body <<<"$plan"
if [[ "$rc" == "0" ]]; then
  printf '%s' "$body" >"$out"
else
  # curl --fail leaves no usable payload behind.
  : >"$out"
  printf 'curl: (%s) The requested URL returned error: %s\n' "$rc" "$code" >&2
fi
printf '%s' "$code"
exit "$rc"
STUB

cat >"$stub_dir/tar" <<'STUB'
#!/bin/bash
# Only an intact archive that contains the requested member lists or extracts.
set -u
printf '%s\n' "$*" >>"$CASE_DIR/tar-args"
case "$1" in
  -tzf) mode=list; file="$2"; member="${3:-}" ;;
  -xzf) mode=extract; file="$2"; dest="$4"; member="${5:-}" ;;
  *) printf 'unexpected tar invocation: %s\n' "$*" >&2; exit 2 ;;
esac
if [[ "$(cat "$file" 2>/dev/null)" != "ocm-backplane-archive" ]]; then
  printf 'gzip: stdin: not in gzip format\n' >&2
  exit 1
fi
if [[ "$member" != "ocm-backplane" ]]; then
  printf 'tar: %s: Not found in archive\n' "$member" >&2
  exit 2
fi
if [[ "$mode" == list ]]; then
  printf 'ocm-backplane\n'
  exit 0
fi
cp "$STUB_DIR/ocm-backplane" "$dest/ocm-backplane"
printf 'extracted\n' >>"$CASE_DIR/extractions"
STUB

cat >"$stub_dir/ocm" <<'STUB'
#!/bin/bash
# Record the subcommand only: the arguments carry credentials.
printf '%s\n' "${1:-}" >>"$CASE_DIR/ocm-calls"
STUB

cat >"$stub_dir/ocm-backplane" <<'STUB'
#!/bin/bash
set -u
printf '%s\n' "${1:-}" >>"$CASE_DIR/backplane-calls"
if [[ "${1:-}" == elevate && "$*" == *"config view"* ]]; then
  cat <<'KUBECONFIG'
apiVersion: v1
kind: Config
users:
- name: backplane-cluster-admin
  user:
    as: backplane-cluster-admin
KUBECONFIG
fi
STUB

cat >"$stub_dir/oc" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CASE_DIR/oc-calls"
printf 'backplane-cluster-admin\n'
STUB

cat >"$stub_dir/sleep" <<'STUB'
#!/bin/bash
printf '%s\n' "${1:-}" >>"$CASE_DIR/sleeps"
STUB

cat >"$stub_dir/date" <<'STUB'
#!/bin/bash
# Wall clock only moves when a case asks for it (DATE_STEP seconds per reading),
# so elapsed times and the download budget are deterministic.
if [[ "${1:-}" == "+%s" ]]; then
  n=$(( $(cat "$CASE_DIR/date-count" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" >"$CASE_DIR/date-count"
  printf '%s\n' "$(( 1763000000 + n * ${DATE_STEP:-0} ))"
else
  printf '01-01-2026T00:00:00\n'
fi
STUB

chmod 0755 "$stub_dir"/*

scenario=""
fail() {
    printf 'FAIL: %s: %s\n' "$scenario" "$1" >&2
}

assert_file_has() {
    local needle="$1" file="$2" what="$3"
    if ! grep -Fq -- "$needle" "$file"; then
        fail "$what"
        return 1
    fi
}

# run_case <scenario> <curl plan> <exit> <attempts> <delays> <outcome> <extractions> <extra env>
#          [max-times]
# <delays> is the comma-joined backoff sequence ("-" when no retry is expected);
# <extra env> is "-" or KEY=VAL pairs, with the token "xtrace" running the step
# under `bash -x` to prove the credential tracing guard holds; [max-times] is the
# comma-joined per-attempt curl --max-time sequence, defaulting to 300 each.
run_case() {
    scenario="$1"
    local plan="$2" expected_status="$3" expected_attempts="$4" expected_delays="$5" \
        expected_outcome="$6" expected_extractions="$7" extra="$8" expected_max_times="${9:--}"
    local case_dir="$test_dir/$scenario" result=0 delays max_times i
    local -a case_env=() bash_flags=()
    mkdir -p "$case_dir"/{shared,artifacts,profile,home}
    printf '%s\n' "$plan" >"$case_dir/curl-plan"
    printf '0\n' >"$case_dir/curl-count"
    : >"$case_dir/curl-args"; : >"$case_dir/tar-args"; : >"$case_dir/sleeps"
    : >"$case_dir/extractions"; : >"$case_dir/backplane-calls"; : >"$case_dir/ocm-calls"
    : >"$case_dir/oc-calls"
    printf '%s\n' "$cluster_id_sentinel" >"$case_dir/shared/cluster-id"
    printf '%s\n' "$client_id_sentinel" >"$case_dir/profile/sso-client-id"
    printf '%s\n' "$client_secret_sentinel" >"$case_dir/profile/sso-client-secret"
    if [[ "$extra" != "-" ]]; then
        for item in $extra; do
            if [[ "$item" == xtrace ]]; then bash_flags+=(-x); else case_env+=("$item"); fi
        done
    fi
    if [[ "$expected_max_times" == - ]]; then
        expected_max_times=""
        for ((i = 0; i < expected_attempts; i++)); do
            expected_max_times+="${expected_max_times:+,}300"
        done
    fi

    env -i \
        PATH="$stub_dir:/usr/bin:/bin" \
        HOME="$case_dir/home" \
        CASE_DIR="$case_dir" \
        STUB_DIR="$stub_dir" \
        SHARED_DIR="$case_dir/shared" \
        CLUSTER_PROFILE_DIR="$case_dir/profile" \
        ARTIFACT_DIR="$case_dir/artifacts" \
        OCM_LOGIN_ENV=staging \
        BACKPLANE_LOGIN_RETRIES=1 \
        ${case_env[@]+"${case_env[@]}"} \
        bash ${bash_flags[@]+"${bash_flags[@]}"} "$script" \
        >"$case_dir/stdout" 2>"$case_dir/stderr" || result=$?

    local diag="$case_dir/artifacts/backplane-cli-download.txt"
    if [[ "$result" != "$expected_status" ]]; then
        fail "expected exit $expected_status, got $result"
        return 1
    fi
    if [[ "$(wc -l <"$case_dir/curl-args")" -ne "$expected_attempts" ||
          "$(wc -l <"$case_dir/extractions")" -ne "$expected_extractions" ]]; then
        fail "unexpected download attempt or extraction count"
        return 1
    fi
    delays="$(paste -sd, "$case_dir/sleeps")"
    if [[ "${delays:--}" != "$expected_delays" ]]; then
        fail "expected backoff delays [$expected_delays], got [${delays:--}]"
        return 1
    fi
    # Every attempt must use the pinned URL and a --max-time within the budget.
    max_times="$(sed -n 's/.*--max-time \([0-9]*\).*/\1/p' "$case_dir/curl-args" | paste -sd,)"
    if [[ "$max_times" != "$expected_max_times" ]]; then
        fail "expected curl --max-time sequence [$expected_max_times], got [$max_times]"
        return 1
    fi
    if [[ "$expected_attempts" -gt 0 ]]; then
        assert_file_has "$pinned_url_path" "$case_dir/curl-args" "download did not use the pinned release URL" || return 1
    fi
    if ! grep -Fqx "outcome: $expected_outcome" "$diag"; then
        fail "diagnostics missing \"outcome: $expected_outcome\""
        return 1
    fi
    if [[ "$(grep -c '^  attempt=' "$diag")" -ne "$expected_attempts" ]] ||
       { [[ "$expected_attempts" -gt 0 ]] &&
         ! grep -Eq '^  attempt=1 http_code=[0-9]+ curl_exit=[0-9]+ elapsed=[0-9]+s result=' "$diag"; }; then
        fail "diagnostics lack per-attempt HTTP/exit/elapsed evidence"
        return 1
    fi
    # Diagnostics must stay free of credentials, cluster id, URLs and headers.
    if grep -Fq -e "$client_id_sentinel" -e "$client_secret_sentinel" -e "$cluster_id_sentinel" \
            -e "$override_sentinel" "$diag" ||
       grep -Eq 'https?://|[Aa]uthorization' "$diag"; then
        fail "download diagnostics leaked sensitive detail"
        return 1
    fi
    # Credentials, and an arbitrary invalid override, must stay out of the log.
    if grep -Fq -e "$client_id_sentinel" -e "$client_secret_sentinel" -e "$override_sentinel" \
        "$case_dir/stdout" "$case_dir/stderr" "$diag"; then
        fail "credentials or a raw invalid override reached the step log"
        return 1
    fi

    if [[ "$expected_status" == 0 ]]; then
        # The pinned version is installed and the original login, elevation and
        # kubeconfig behaviour is unchanged.
        assert_file_has 'Installing ocm-backplane CLI v0.12.0' "$case_dir/stdout" "pinned version not logged" || return 1
        assert_file_has 'ocm-backplane_0.12.0_Linux_x86_64.tar.gz' "$diag" "diagnostics lost the pinned asset" || return 1
        assert_file_has 'login' "$case_dir/ocm-calls" "ocm login did not run" || return 1
        assert_file_has 'login' "$case_dir/backplane-calls" "ocm-backplane login did not run" || return 1
        assert_file_has 'elevate' "$case_dir/backplane-calls" "ocm-backplane elevate did not run" || return 1
        assert_file_has 'whoami' "$case_dir/oc-calls" "kubeconfig was not validated with oc whoami" || return 1
        assert_file_has 'backplane-cluster-admin' "$case_dir/shared/kubeconfig" "kubeconfig is not elevated" || return 1
        assert_file_has 'squid.corp.redhat.com:3128' "$case_dir/shared/proxy-conf.sh" "proxy-conf.sh not written" || return 1
        if [[ "$(stat -c '%a' "$case_dir/shared/kubeconfig")" != "600" ]]; then
            fail "kubeconfig is not mode 0600"
            return 1
        fi
        # Exactly one integrity check and one extraction, both for the pinned member.
        if [[ "$(grep -c -- '-tzf' "$case_dir/tar-args")" -ne 1 ||
              "$(grep -c -- '-xzf' "$case_dir/tar-args")" -ne 1 ]] ||
           ! grep -q -- '-xzf .* ocm-backplane$' "$case_dir/tar-args"; then
            fail "unexpected tar usage on the success path"
            return 1
        fi
    else
        # A failed download is never extracted, executed or bootstrapped from.
        if grep -q -- '-xzf' "$case_dir/tar-args"; then
            fail "a failed download was handed to tar for extraction"
            return 1
        fi
        if [[ -s "$case_dir/backplane-calls" || -e "$case_dir/shared/kubeconfig" ||
              -e "$case_dir/shared/proxy-conf.sh" ]]; then
            fail "step continued after a failed download"
            return 1
        fi
        assert_file_has 'bootstrap unavailable' "$diag" "diagnostics do not record bootstrap unavailability" || return 1
        assert_file_has 'ERROR: failed to install the pinned ocm-backplane CLI' "$case_dir/stderr" "hard failure not reported" || return 1
    fi
    printf 'PASS: %s\n' "$scenario"
}

#        scenario           curl plan                                        exit attempts delays       outcome           extr env
run_case transient-504     $'504 22 x\n504 22 x\n200 0 ocm-backplane-archive'  0    3        '5,10'       succeeded         1   -
run_case retries-exhausted $'504 22 x'                                         1    5        '5,10,20,30' failed-exhausted  0   -
run_case retries-override  $'503 22 x'                                         1    2        '5'          failed-exhausted  0   BACKPLANE_DOWNLOAD_RETRIES=2
run_case budget-exhausted  $'504 22 x'                                         1    1        '5'          failed-exhausted  0   DATE_STEP=120
run_case permanent-404     $'404 22 x'                                         1    1        -            failed-permanent  0   -
run_case permanent-403     $'403 22 x'                                         1    1        -            failed-permanent  0   -
run_case corrupt-archive   $'200 0 truncated'                                  1    5        '5,10,20,30' failed-exhausted  0   -
run_case transport-error   $'000 28 x\n200 0 ocm-backplane-archive'            0    2        '5'          succeeded         1   -
run_case xtrace-redaction  $'200 0 ocm-backplane-archive'                      0    1        -            succeeded         1   xtrace
# An invalid BACKPLANE_DOWNLOAD_RETRIES falls back to the default 5 attempts:
# a non-numeric value otherwise aborts the shell mid-loop, 0 skips all retries,
# a leading zero is read as octal (or errors), and a huge value never trips the
# attempt limit at all. The raw value is never echoed back.
run_case bad-retries-word  $'504 22 x'                                         1    5        '5,10,20,30' failed-exhausted  0   BACKPLANE_DOWNLOAD_RETRIES=abcRETRIESSENTINEL
run_case bad-retries-zero  $'504 22 x'                                         1    5        '5,10,20,30' failed-exhausted  0   BACKPLANE_DOWNLOAD_RETRIES=0
run_case bad-retries-08    $'504 22 x'                                         1    5        '5,10,20,30' failed-exhausted  0   BACKPLANE_DOWNLOAD_RETRIES=08
run_case bad-retries-010   $'504 22 x'                                         1    5        '5,10,20,30' failed-exhausted  0   BACKPLANE_DOWNLOAD_RETRIES=010
run_case bad-retries-huge  $'504 22 x'                                         1    5        '5,10,20,30' failed-exhausted  0   BACKPLANE_DOWNLOAD_RETRIES=99999999999999999999
# No single attempt may outlive the remaining budget, and an exhausted budget
# stops the loop before another download starts.
run_case max-time-capped   $'504 22 x'                                         1    2        '5'          failed-exhausted  0   DATE_STEP=80  '300,200'
run_case budget-pre-stop   $'504 22 x'                                         1    0        -            failed-exhausted  0   DATE_STEP=600
# The rest of the retry classification: a throttled (429) or timed-out (408)
# request recovers on the next attempt, while an authentication failure (401)
# and a transport error that a retry cannot fix (curl 60, the server
# certificate failed verification) fail on the first attempt.
run_case transient-429     $'429 22 x\n200 0 ocm-backplane-archive'            0    2        '5'          succeeded         1   -
run_case transient-408     $'408 22 x\n200 0 ocm-backplane-archive'            0    2        '5'          succeeded         1   -
run_case permanent-401     $'401 22 x'                                         1    1        -            failed-permanent  0   -
run_case permanent-curl-60 $'000 60 x'                                         1    1        -            failed-permanent  0   -
