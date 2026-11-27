#!/bin/bash
#
# rosa-gap-analysis-job-sync — auto-onboard new OCP y-streams into the gap-analysis periodics.
#
# What it does:
#   1. Reads accepted OCP nightly streams from the release-controller API.
#   2. Reads the nightly-X-Y tests currently defined in openshift/release (raw.githubusercontent.com, read-only).
#   3. Reports accepted y-streams that have no nightly-X-Y job yet. New majors (e.g. 6.0) are skipped with a log.
#   4. DRY-RUN (default): logs what it would do and writes a preview
#      artifact. Write mode (GAP_JOB_SYNC_DRY_RUN=false, requires a GitHub token): opens ONE PR adding the templated nightly-X-Y entry for every missing y-stream,
#      including the regenerated ci-operator/jobs output — the release repo's
#      generator binaries are extracted from the public ci-public image and
#      run directly (the job image has no container engine, so make update
#      cannot run there).
#
# The step is stateless: its only input is the periodics config on main
# (is the job present?). One run opens one PR, and the PR auto-merges —
# by the next daily run the job is on main and there is nothing to do.
#
# The nightly-X-Y entry template and cron-slot rule mirror the existing
# hand-maintained jobs byte-for-byte so the generated diff is minimal.
#
# Env:
#   GAP_JOB_SYNC_DRY_RUN  "true" (default) | "false"
#   GITHUB_TOKEN          token for write mode (env)
#   GITHUB_TOKEN_PATH     token file for write mode (default /creds-github/token)

set -euo pipefail

readonly RELEASE_CONTROLLER_API="${RELEASE_CONTROLLER_API:-https://amd64.ocp.releases.ci.openshift.org}"
readonly RELEASE_CONTROLLER_RETRIES="${RELEASE_CONTROLLER_RETRIES:-3}"
readonly RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS:-2}"
readonly RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS:-30}"
readonly RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}"
readonly CURL_BIN="${CURL_BIN:-curl}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly GIT_BIN="${GIT_BIN:-git}"
readonly GH_BIN="${GH_BIN:-gh}"
readonly OC_BIN="${OC_BIN:-oc}"
readonly SLEEP_BIN="${SLEEP_BIN:-sleep}"

readonly PERIODICS_RAW_URL="https://raw.githubusercontent.com/openshift/release/main/ci-operator/config/openshift-online/rosa-gap-analysis/openshift-online-rosa-gap-analysis-main__periodics.yaml"
readonly RELEASE_REPO_SLUG="openshift/release"
readonly RELEASE_REPO_URL="https://github.com/openshift/release.git"
readonly PERIODICS_REPO_PATH="ci-operator/config/openshift-online/rosa-gap-analysis/openshift-online-rosa-gap-analysis-main__periodics.yaml"
readonly PERIODICS_JOBS_PATH="ci-operator/jobs/openshift-online/rosa-gap-analysis"
# The generators are narrowed to this ci-operator config subdir (same WHAT
# the release Makefile targets accept).
readonly SYNC_CONFIG_SUBDIR="openshift-online/rosa-gap-analysis"
# Public image shipping the release repo's generator binaries.
readonly GENERATOR_IMAGE="quay.io/openshift/ci-public:ci_auto-config-brancher_latest"

# Branch prefix for the PRs this step opens.
readonly SYNC_BRANCH_PREFIX="gap-analysis-add-nightly-"

readonly DRY_RUN="${GAP_JOB_SYNC_DRY_RUN:-true}"
readonly GITHUB_TOKEN_PATH="${GITHUB_TOKEN_PATH:-/creds-github/token}"

readonly ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp}"
readonly WOULD_DO_FILE="${ARTIFACT_DIR}/rosa-gap-analysis-job-sync-would-do.txt"
readonly SHARED_DIR="${SHARED_DIR:-/tmp}"

WORK_DIR=""
RELEASE_BASE_SHA=""

cleanup() {
  if [[ -n "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

log() {
  printf '[rosa-gap-analysis-job-sync] %s\n' "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_settings() {
  [[ "${DRY_RUN}" == "true" || "${DRY_RUN}" == "false" ]] \
    || fail "GAP_JOB_SYNC_DRY_RUN must be true or false"
  [[ "${RELEASE_CONTROLLER_API}" == https://* ]] || fail "RELEASE_CONTROLLER_API must use https://"
  [[ "${RELEASE_CONTROLLER_RETRIES}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_RETRIES must be a positive integer"
  [[ "${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS}" =~ ^[0-9]+$ ]] \
    || fail "RELEASE_CONTROLLER_RETRY_DELAY_SECONDS must be a non-negative integer"
  [[ "${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
    || fail "RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS must be a positive integer"
  (( RELEASE_CONTROLLER_RETRY_DELAY_SECONDS <= RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS )) \
    || fail "RELEASE_CONTROLLER_RETRY_DELAY_SECONDS must not exceed RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS"
  mkdir -p "${ARTIFACT_DIR}"
  mkdir -p "${SHARED_DIR}"
  require_command "${CURL_BIN}"
  require_command mktemp
  require_command "${PYTHON_BIN}"
  require_command rm
  require_command "${SLEEP_BIN}"
}

http_get() {
  local url="$1"
  local destination="$2"
  local request_name="$3"
  local attempt=1
  local curl_rc=0
  local http_code=""
  local retry_delay="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS}"

  while (( attempt <= RELEASE_CONTROLLER_RETRIES )); do
    if http_code=$("${CURL_BIN}" \
      --silent \
      --show-error \
      --proto '=https' \
      --proto-redir '=https' \
      --location \
      --connect-timeout 10 \
      --max-time 30 \
      --max-filesize "${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES}" \
      --output "${destination}" \
      --write-out '%{http_code}' \
      "${url}"); then
      curl_rc=0
    else
      curl_rc=$?
    fi

    if (( curl_rc == 0 )) && [[ "${http_code}" == "200" ]] && [[ -s "${destination}" ]]; then
      return 0
    fi

    if (( attempt == RELEASE_CONTROLLER_RETRIES )); then
      fail "${request_name} request failed after ${RELEASE_CONTROLLER_RETRIES} attempts (curl_rc=${curl_rc}, http_code=${http_code:-none})"
    fi

    log "${request_name} request failed (attempt ${attempt}/${RELEASE_CONTROLLER_RETRIES}); retrying"
    if (( retry_delay > 0 )); then
      "${SLEEP_BIN}" "${retry_delay}"
      retry_delay=$(( retry_delay * 2 ))
      if (( retry_delay > RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS )); then
        retry_delay="${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS}"
      fi
    fi
    attempt=$(( attempt + 1 ))
  done
}

# Output is newest X.Y first.
discover_accepted_nightly_streams() {
  local accepted_file="$1"

  "${PYTHON_BIN}" - "${accepted_file}" <<'PYTHON'
import json
import re
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        accepted_streams = json.load(source)
except (OSError, ValueError):
    sys.exit(2)

if not isinstance(accepted_streams, dict):
    sys.exit(2)

nightly_pattern = re.compile(r"^(\d+)\.(\d+)\.0-0\.nightly$")
nightly_versions = set()
for stream, payloads in accepted_streams.items():
    match = nightly_pattern.fullmatch(stream)
    if not match:
        continue
    if not isinstance(payloads, list) or any(not isinstance(item, str) for item in payloads):
        sys.exit(2)
    if payloads:
        nightly_versions.add((int(match.group(1)), int(match.group(2))))

for major, minor in sorted(nightly_versions, reverse=True):
    print("{}.{}".format(major, minor))
PYTHON
}

# The periodics YAML is deterministically formatted, so a line-oriented scan
# stays stable across regenerations.
# Output format: "<X.Y> <cron-minute> <cron-hour>" (one line per job).
extract_existing_jobs() {
  local periodics_file="$1"

  "${PYTHON_BIN}" - "${periodics_file}" <<'PYTHON'
import re
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        periodics_text = source.read()
except OSError:
    sys.exit(2)

pattern = re.compile(r"- as: nightly-(\d+)-(\d+)\n\s+cron: (\d+) (\d+) \* \* \*")
for match in pattern.finditer(periodics_text):
    print("{}.{} {} {}".format(match.group(1), match.group(2), match.group(3), match.group(4)))
PYTHON
}

# Onboarding guards. The accepted API retains nightly streams — with live
# payloads — for long-EOL versions (4.11, 4.12, ...), so "missing a job" is
# not enough. A missing X.Y is only a candidate when it is NEWER than the
# newest tracked minor of its major (y-stream onboarding, no backfilling);
# older y-streams are reported as OLDER and ignored; a missing NEW major is
# a manual, loud SKIP — majors need product judgment (see ROSAENG-66067).
compute_missing_versions() {
  local active_versions_file="$1"
  local existing_jobs_file="$2"

  "${PYTHON_BIN}" - "${active_versions_file}" "${existing_jobs_file}" <<'PYTHON'
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        active_versions = [line.strip() for line in source if line.strip()]
    with open(sys.argv[2], "r", encoding="utf-8") as source:
        existing_job_lines = source.read().splitlines()
except OSError:
    sys.exit(2)

existing_versions = set()
newest_tracked_minor = {}
for existing_job_line in existing_job_lines:
    fields = existing_job_line.split()
    if not fields:
        continue
    existing_versions.add(fields[0])
    major, minor = fields[0].split(".")
    newest_tracked_minor[major] = max(newest_tracked_minor.get(major, -1), int(minor))

# dict.fromkeys dedups while preserving the newest-first order; duplicate
# input would otherwise render the same entry twice in one PR.
for version in dict.fromkeys(active_versions):
    if version in existing_versions:
        continue
    major, minor = version.split(".")
    if major not in newest_tracked_minor:
        print("SKIP {}".format(version))
    elif int(minor) <= newest_tracked_minor[major]:
        print("OLDER {}".format(version))
    else:
        print("MISSING {}".format(version))
PYTHON
}

# Jobs are staggered purely to spread load; slots start at 06:00 UTC.
# Input lines use the extract_existing_jobs format: "<X.Y> <minute> <hour>".
# When the day wraps, scan for the first genuinely free slot instead of
# resetting to a slot that is occupied by construction.
next_cron_slot() {
  local cron_slots_file="$1"

  "${PYTHON_BIN}" - "${cron_slots_file}" <<'PYTHON'
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        slot_lines = source.read().splitlines()
except OSError:
    sys.exit(2)

used_slots = set()
latest_slot = 6 * 60  # first slot of the day, 06:00 UTC
for slot_line in slot_lines:
    fields = slot_line.split()
    if len(fields) < 3:
        continue
    try:
        slot_minutes = int(fields[2]) * 60 + int(fields[1])
    except ValueError:
        continue
    used_slots.add(slot_minutes)
    if slot_minutes > latest_slot:
        latest_slot = slot_minutes

chosen_slot = latest_slot + 30
if chosen_slot >= 24 * 60:
    chosen_slot = None
    candidate_slot = 6 * 60
    while candidate_slot < 24 * 60:
        if candidate_slot not in used_slots:
            chosen_slot = candidate_slot
            break
        candidate_slot += 30
    if chosen_slot is None:
        sys.exit("no free 30-minute cron slot between 06:00 and 23:30 UTC")
print("{} {}".format(chosen_slot % 60, chosen_slot // 60))
PYTHON
}

# Byte-identical in shape to the existing hand-maintained entries;
# determinize-ci-operator accepts this format.
render_job_block() {
  local version="$1"   # dotted, e.g. 4.23
  local cron_slot="$2" # "M H"

  local dashed="${version//./-}"

  printf '%s\n' \
"- as: nightly-${dashed}" \
"  cron: ${cron_slot} * * *" \
"  steps:" \
"    test:" \
"    - as: ${dashed}-gap-analysis" \
"      commands: |-" \
"        set -euo pipefail" \
"        mkdir -p \${ARTIFACT_DIR}/rosa-gap-analysis-reports" \
"        export REPORT_DIR=\${ARTIFACT_DIR}/rosa-gap-analysis-reports" \
"        export OPENSHIFT_VERSION=${version}" \
"        export OCM_CLIENT_ID=\$(cat /var/run/ocm-credentials/sso-client-id)" \
"        export OCM_CLIENT_SECRET=\$(cat /var/run/ocm-credentials/sso-client-secret)" \
"        export OCM_URL=stage" \
"        ./scripts/gap-all.sh" \
"      credentials:" \
"      - collection: rosa-e2e" \
"        group: gap-analysis" \
"        mount_path: /var/run/ocm-credentials" \
"      from: src" \
"      resources:" \
"        requests:" \
"          cpu: 100m" \
"          memory: 200Mi"
}

load_github_token() {
  # Never log the token value.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ -f "${GITHUB_TOKEN_PATH}" ]]; then
    GITHUB_TOKEN=$(<"${GITHUB_TOKEN_PATH}")
    return 0
  fi
  fail "write mode requires GITHUB_TOKEN or a token file at ${GITHUB_TOKEN_PATH}"
}

# One-time write-mode setup: authenticate git through gh (keeps the token
# out of URLs and argv) and clone release once per run.
prepare_release_checkout() {
  load_github_token
  export GH_TOKEN="${GITHUB_TOKEN}"
  require_command "${GIT_BIN}"
  require_command "${GH_BIN}"
  require_command "${OC_BIN}"
  "${GH_BIN}" auth setup-git >/dev/null
  "${GIT_BIN}" clone --depth 1 "${RELEASE_REPO_URL}" "${WORK_DIR}/release"
  RELEASE_BASE_SHA=$("${GIT_BIN}" -C "${WORK_DIR}/release" rev-parse HEAD)
}

# Opens ONE PR whose diff inserts every missing entry in a single change —
# separate per-version PRs would all touch the same insertion point and
# conflict with each other.
open_pr_for_versions() {
  local job_entries_path="$1"
  shift
  local -a versions=("$@")
  local branch_name
  local dashed_list=""
  local periodic_word="periodic"
  local version
  local release_dir="${WORK_DIR}/release"

  for version in "${versions[@]}"; do
    if [[ -n "${dashed_list}" ]]; then
      dashed_list+=", "
    fi
    dashed_list+="nightly-${version//./-}"
  done
  if (( ${#versions[@]} > 1 )); then
    periodic_word="periodics"
  fi

  # A stale remote branch from a previously closed, unmerged PR must not
  # block a retry with a non-fast-forward push.
  branch_name="${SYNC_BRANCH_PREFIX}$(date -u +%Y%m%d%H%M%S)"
  "${GIT_BIN}" -C "${release_dir}" checkout -B "${branch_name}" "${RELEASE_BASE_SHA}"

  "${PYTHON_BIN}" - "${release_dir}/${PERIODICS_REPO_PATH}" "${job_entries_path}" <<'PYTHON'
import sys

periodics_path = sys.argv[1]
job_entries_path = sys.argv[2]
with open(periodics_path, "r", encoding="utf-8") as source:
    periodics_text = source.read()
with open(job_entries_path, "r", encoding="utf-8") as source:
    job_entries_text = source.read()

marker = "zz_generated_metadata:"
if marker not in periodics_text:
    sys.exit("marker not found in periodics file")

periodics_text = periodics_text.replace(marker, job_entries_text + marker, 1)
with open(periodics_path, "w", encoding="utf-8") as sink:
    sink.write(periodics_text)
PYTHON

  # Regenerate the ci-operator/jobs output by running the release repo's
  # generator binaries directly: the job image has no container engine, so
  # make update (which wraps these tools in containers) cannot run here.
  # The binaries are static linux executables pulled from the public
  # ci-public image, and the invocation was verified to produce
  # byte-identical output. Prowgen uses explicit --from-dir/--to-dir
  # instead of the Makefile's --from-release-repo/--to-release-repo: those
  # resolve through $GOPATH, which is neither set nor laid out in this
  # job. Determinize runs first, deliberately (make update runs it last):
  # the inserted entries are already determinize-formatted, so both orders
  # converge to the same bytes.
  local regeneration_note="regenerate ci-operator/jobs before merging"
  local generator_bin_dir="${WORK_DIR}/generator-bin"
  mkdir -p "${generator_bin_dir}"
  if "${OC_BIN}" image extract "${GENERATOR_IMAGE}" \
      --path "/usr/bin/determinize-ci-operator:${generator_bin_dir}" \
      --path "/usr/bin/ci-operator-prowgen:${generator_bin_dir}" \
      --path "/usr/bin/sanitize-prow-jobs:${generator_bin_dir}" \
      --confirm &&
     chmod +x "${generator_bin_dir}"/* &&
     (cd "${release_dir}" &&
      "${generator_bin_dir}/determinize-ci-operator" --config-dir ci-operator/config --confirm &&
      "${generator_bin_dir}/ci-operator-prowgen" \
        --from-dir "${release_dir}/ci-operator/config" \
        --to-dir "${release_dir}/ci-operator/jobs" \
        --registry "${release_dir}/ci-operator/step-registry" \
        --managed-repos-config "${release_dir}/core-services/prow/_managed-repos.yaml" \
        --known-infra-file infra-build-farm-periodics.yaml \
        --known-infra-file infra-periodics.yaml \
        --known-infra-file infra-periodics-migrated.yaml \
        --known-infra-file infra-image-mirroring.yaml \
        --known-infra-file infra-periodics-origin-release-images.yaml \
        "${SYNC_CONFIG_SUBDIR}" &&
      "${generator_bin_dir}/sanitize-prow-jobs" --prow-jobs-dir ci-operator/jobs \
        --config-path core-services/sanitize-prow-jobs/_config.yaml \
        "${SYNC_CONFIG_SUBDIR}"); then
    regeneration_note="ci-operator/jobs regenerated by the release generator binaries"
    # Unrelated drift in the rest of ci-operator/jobs must not ride along.
    if [[ -d "${release_dir}/${PERIODICS_JOBS_PATH}" ]]; then
      "${GIT_BIN}" -C "${release_dir}" add "${PERIODICS_JOBS_PATH}"
    fi
  else
    log "WARNING: generator run failed — committing the config change only"
    # A failed generator may leave partial jobs output; discard it so the
    # commit really is config-only, as the PR body claims. The clone is
    # pristine at RELEASE_BASE_SHA, so every jobs-dir change is
    # generator-caused and safe to drop.
    "${GIT_BIN}" -C "${release_dir}" checkout -- "${PERIODICS_JOBS_PATH}"
    "${GIT_BIN}" -C "${release_dir}" clean -fd "${PERIODICS_JOBS_PATH}"
  fi

  "${GIT_BIN}" -C "${release_dir}" add "${PERIODICS_REPO_PATH}"
  "${GIT_BIN}" -C "${release_dir}" \
    -c user.name="rosa-gap-analysis-job-sync" \
    -c user.email="rosa-gap-analysis-job-sync@ci" \
    commit -m "Add ${dashed_list} gap-analysis ${periodic_word} (ROSAENG-66067)"
  "${GIT_BIN}" -C "${release_dir}" push origin "${branch_name}"

  "${GH_BIN}" pr create --repo "${RELEASE_REPO_SLUG}" \
    --head "${branch_name}" \
    --title "Add ${dashed_list} gap-analysis ${periodic_word}" \
    --body "Automated by rosa-gap-analysis-job-sync (ROSAENG-66067).

OCP y-stream(s) without a gap-analysis periodic: ${versions[*]}.
This PR adds the templated entries, one per version, each with its own cron slot.

Note: ${regeneration_note}." >/dev/null

  # TODO(ROSAENG-66067, Phase 2): apply the lgtm label so Tide can auto-merge,
  # matching the autoowners flow — enable once DPTP confirms label-only merge
  # is allowed on the gap-analysis config path.
  # "${GH_BIN}" pr edit --repo "${RELEASE_REPO_SLUG}" "${branch_name}" --add-label lgtm

  log "opened PR for ${dashed_list}"
}

main() {
  local accepted_streams_path
  local periodics_yaml_path
  local existing_jobs_path
  local missing_results_path
  local cron_slots_path
  local job_entries_path
  local preview_path
  local -a missing_versions=()
  local -a skipped_new_major_versions=()
  local -a older_untracked_versions=()
  local result_line
  local version
  local cron_slot

  validate_settings
  # Drop the previous run's preview so the artifact always reflects this run.
  rm -f -- "${WOULD_DO_FILE}"
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rosa-gap-analysis-job-sync.XXXXXX") \
    || fail "failed to create temporary work directory"
  trap cleanup EXIT
  accepted_streams_path="${WORK_DIR}/accepted-nightlies.json"
  periodics_yaml_path="${WORK_DIR}/periodics.yaml"
  existing_jobs_path="${WORK_DIR}/existing-jobs.txt"
  missing_results_path="${WORK_DIR}/missing.txt"
  # Cron slots claimed during this run are appended here so successive
  # versions get successive slots instead of sharing one.
  cron_slots_path="${WORK_DIR}/slots.txt"
  # Rendered YAML entries (inserted verbatim before zz_generated_metadata).
  job_entries_path="${WORK_DIR}/job-entries.yaml"
  # The same entries plus per-version headers (the dry-run preview artifact).
  preview_path="${WORK_DIR}/would-do-preview.txt"

  http_get "${RELEASE_CONTROLLER_API}/api/v1/releasestreams/accepted" \
    "${accepted_streams_path}" "accepted-nightlies"
  discover_accepted_nightly_streams "${accepted_streams_path}" > "${WORK_DIR}/active.txt" \
    || fail "invalid accepted OCP nightly response"

  http_get "${PERIODICS_RAW_URL}" "${periodics_yaml_path}" "periodics-yaml"
  extract_existing_jobs "${periodics_yaml_path}" > "${existing_jobs_path}" \
    || fail "could not parse existing periodics"

  compute_missing_versions "${WORK_DIR}/active.txt" "${existing_jobs_path}" > "${missing_results_path}" \
    || fail "could not compute missing versions"
  while IFS= read -r result_line; do
    case "${result_line}" in
      SKIP*) skipped_new_major_versions+=("${result_line#SKIP }") ;;
      OLDER*) older_untracked_versions+=("${result_line#OLDER }") ;;
      MISSING*) missing_versions+=("${result_line#MISSING }") ;;
    esac
  done < "${missing_results_path}"

  if (( ${#skipped_new_major_versions[@]} > 0 )); then
    for version in "${skipped_new_major_versions[@]}"; do
      log "x-stream skip: ${version} is a new major — onboarding is manual by design (ROSAENG-66067)"
    done
  fi

  if (( ${#older_untracked_versions[@]} > 0 )); then
    log "older y-streams without jobs, not onboarded (no backfilling): ${older_untracked_versions[*]}"
  fi

  if (( ${#missing_versions[@]} == 0 )); then
    log "No action: all accepted y-streams already have a nightly-X-Y job"
    printf 'No action: all-y-streams-onboarded\n' > "${SHARED_DIR}/rosa-gap-analysis-job-sync-state"
    return 0
  fi

  log "Accepted y-stream(s) without a nightly-X-Y job: ${missing_versions[*]}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    prepare_release_checkout
  fi

  cp -- "${existing_jobs_path}" "${cron_slots_path}"
  local rendered_entry_path="${WORK_DIR}/rendered-entry.yaml"
  for version in "${missing_versions[@]}"; do
    cron_slot=$(next_cron_slot "${cron_slots_path}") || fail "could not compute next cron slot"
    log "candidate: nightly-${version//./-} (cron ${cron_slot} * * *)"
    render_job_block "${version}" "${cron_slot}" > "${rendered_entry_path}"
    cat -- "${rendered_entry_path}" >> "${job_entries_path}"
    printf 'would add nightly-%s (OPENSHIFT_VERSION=%s, cron %s * * *)\n' \
      "${version//./-}" "${version}" "${cron_slot}" >> "${preview_path}"
    cat -- "${rendered_entry_path}" >> "${preview_path}"
    printf '\n' >> "${preview_path}"
    # "pending" is a placeholder version field; next_cron_slot only reads
    # the minute/hour fields.
    printf 'pending %s\n' "${cron_slot}" >> "${cron_slots_path}"
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    cp -- "${preview_path}" "${WOULD_DO_FILE}"
    log "DRY-RUN: would open ONE PR adding: ${missing_versions[*]} (preview in ${WOULD_DO_FILE})"
  else
    open_pr_for_versions "${job_entries_path}" "${missing_versions[@]}"
  fi

  printf 'ready\n' > "${SHARED_DIR}/rosa-gap-analysis-job-sync-state"
}

main "$@"
