#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================================
# SECURITY WARNING: This script handles sensitive credentials
# ============================================================================
# - Azure service principal credentials (client-id, client-secret, tenant)
# - a short-lived GitHub App installation token written by the preceding
#   aro-hcp-github-app-auth step to ${SHARED_DIR}/github-token
#
# NEVER enable 'set -x' or 'set -o xtrace': it would expose credentials in the
# build log. Use VERBOSITY for controlled logging instead.
# ============================================================================

set +o xtrace
trap 'set +o xtrace' DEBUG
umask 077

readonly MARKER='<!-- aro-hcp-test-priorities:v1 -->'
readonly TITLE='test(e2e): refresh start priority bands'
readonly SCHEDULED_JOB='periodic-ci-Azure-ARO-HCP-main-test-priorities-test-priorities-refresh'
RUNNER=${E2E_RUNNER:-/opt/app-root/src/github.com/Azure/ARO-HCP/test/aro-hcp-tests}
BAKED_REPO=${E2E_BAKED_REPO:-/opt/app-root/src/github.com/Azure/ARO-HCP}
readonly RUNNER BAKED_REPO
readonly API='https://api.github.com'
readonly LOOKBACK_DAYS=7
readonly MAX_PR_PAGES=50

VERBOSITY=${VERBOSITY:-0}
PRIORITIES_PUBLISH=${PRIORITIES_PUBLISH:-false}
AZURE_CREDENTIALS_DIR=${AZURE_CREDENTIALS_DIR:-/var/run/aro-hcp-dev}
KUSTO_CLUSTER=${KUSTO_CLUSTER:-hcp-dev-us-2}
KUSTO_REGION=${KUSTO_REGION:-eastus2}
KUSTO_DATABASE=${KUSTO_DATABASE:-ServiceLogs}
PRIORITIES_LOOKBACK=${PRIORITIES_LOOKBACK:-720h}
PRIORITIES_MIN_SAMPLES=${PRIORITIES_MIN_SAMPLES:-3}
GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER:-Azure}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-ARO-HCP}
GITHUB_BASE_BRANCH=${GITHUB_BASE_BRANCH:-main}
GITHUB_BOT_LOGIN=${GITHUB_BOT_LOGIN:-'aro-hcp-robot[bot]'}
GITHUB_BOT_NAME=${GITHUB_BOT_NAME:-'aro-hcp-robot[bot]'}
GITHUB_BOT_EMAIL=${GITHUB_BOT_EMAIL:-'aro-hcp-robot[bot]@users.noreply.github.com'}
GITHUB_TOKEN_PATH="${SHARED_DIR}/github-token"

# Diagnostics always go to stderr so captured command output stays data only.
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${*}" >&2; }
info() { if [[ ${VERBOSITY} -ge 1 ]]; then log "[info] ${*}"; fi; }
debug() { if [[ ${VERBOSITY} -ge 2 ]]; then log "[debug] ${*}"; fi; }
error() { log "[error] ${*}"; exit 1; }

PRIVATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-priorities.XXXXXX")
cleanup() {
    local exit_code=${?}
    rm -rf "${PRIVATE_DIR}"
    if [[ ${exit_code} -ne 0 ]]; then
        log "[error] test-priorities failed with exit code ${exit_code}"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Configuration and publication mode
# ---------------------------------------------------------------------------
case "${PRIORITIES_PUBLISH}" in
true | false) ;;
*) error "PRIORITIES_PUBLISH must be true or false, got '${PRIORITIES_PUBLISH}'" ;;
esac

if [[ -z "${JOB_SPEC:-}" ]]; then
    error "JOB_SPEC is required to derive the job name, type and build ID"
fi
job_name=$(jq -r '.job // empty' <<<"${JOB_SPEC}") || error "cannot read JOB_SPEC.job"
job_type=$(jq -r '.type // empty' <<<"${JOB_SPEC}") || error "cannot read JOB_SPEC.type"
job_url=$(jq -r '.url // empty' <<<"${JOB_SPEC}") || error "cannot read JOB_SPEC.url"
build_id=$(jq -r '.buildid // empty' <<<"${JOB_SPEC}") || error "cannot read JOB_SPEC.buildid"

publish=${PRIORITIES_PUBLISH}
case "${job_name}" in
rehearse-*)
    info "rehearsal job ${job_name}: forcing read-only behaviour"
    publish=false
    ;;
esac
if [[ "${job_type}" != "periodic" ]]; then
    info "job type ${job_type} is not periodic: forcing read-only behaviour"
    publish=false
fi
if [[ "${publish}" == true ]]; then
    [[ "${job_name}" == "${SCHEDULED_JOB}" ]] ||
        error "publication requires the scheduled job ${SCHEDULED_JOB}, got '${job_name}'"
    [[ "${build_id}" =~ ^[0-9]+$ ]] || error "publication requires a numeric Prow build ID, got '${build_id}'"
fi
info "job ${job_name} (${job_type}), build ${build_id}, publication ${publish}"

for tool in git curl jq go; do
    command -v "${tool}" >/dev/null 2>&1 || error "required tool '${tool}' is not installed"
done

# ---------------------------------------------------------------------------
# Trusted checkout: copy the baked repository at its exact HEAD
# ---------------------------------------------------------------------------
readonly REPO_DIR="${PRIVATE_DIR}/aro-hcp"
[[ -d "${BAKED_REPO}/.git" ]] || error "${BAKED_REPO} is not a git checkout"
[[ -z "$(git -C "${BAKED_REPO}" status --porcelain)" ]] ||
    error "the baked E2E checkout is dirty; refusing to derive a refresh branch from it"
base_sha=$(git -C "${BAKED_REPO}" rev-parse HEAD) || error "cannot resolve the baked HEAD"
info "baked checkout is clean at ${base_sha}"

git clone --quiet --no-hardlinks "${BAKED_REPO}" "${REPO_DIR}" || error "cannot copy the baked checkout"
git -C "${REPO_DIR}" checkout --quiet --detach "${base_sha}" || error "cannot check out ${base_sha}"
[[ -z "$(git -C "${REPO_DIR}" status --porcelain)" ]] || error "the private checkout is not clean"
info "working checkout ${REPO_DIR} at ${base_sha}"

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
readonly GITHUB_TOKEN_FILE="${PRIVATE_DIR}/github-token"
readonly CURL_CONFIG="${PRIVATE_DIR}/curl.conf"

load_github_token() {
    [[ -r "${GITHUB_TOKEN_PATH}" ]] ||
        error "publication requires the GitHub App token at ${GITHUB_TOKEN_PATH}"
    cp "${GITHUB_TOKEN_PATH}" "${GITHUB_TOKEN_FILE}"
    chmod 600 "${GITHUB_TOKEN_FILE}"
    cat >"${CURL_CONFIG}" <<EOF
header = "Authorization: Bearer $(cat "${GITHUB_TOKEN_FILE}")"
header = "Accept: application/vnd.github+json"
silent
show-error
fail-with-body
EOF
    chmod 600 "${CURL_CONFIG}"
}

github_get() {
    curl --config "${CURL_CONFIG}" "https://api.github.com/$1"
}

# open_pull_requests prints "number<TAB>head<TAB>login" for every open pull
# request, failing loudly instead of pretending the list is empty.
open_pull_requests() {
    local page=1 count response
    while ((page <= MAX_PR_PAGES)); do
        response=$(github_get "repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/pulls?state=open&per_page=100&page=${page}") ||
            return 1
        count=$(jq 'length' <<<"${response}") || return 1
        jq -r '.[] | [.number, .head.ref, .user.login] | @tsv' <<<"${response}" || return 1
        if ((count < 100)); then
            return 0
        fi
        page=$((page + 1))
    done
    return 1
}

# publication_blocker prints the reason publication must be skipped, or nothing.
publication_blocker() {
    local listing number head login body
    listing=$(open_pull_requests) || error "cannot list open pull requests; refusing to publish"
    while IFS=$'\t' read -r number head login; do
        [[ -n "${number:-}" ]] || continue
        if [[ -n "${login:-}" && "${login}" == "${GITHUB_BOT_LOGIN}" ]]; then
            body=$(github_get "repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/pulls/${number}") || return 1
            if jq -r '.body // empty' <<<"${body}" | grep -Fq "${MARKER}"; then
                printf 'an open generated pull request #%s already exists\n' "${number}"
                return 0
            fi
            case "${head}" in
            bot/test-priorities-*)
                printf 'an open generated branch pull request #%s already exists\n' "${number}"
                return 0
                ;;
            esac
        fi
        if [[ "${number}" == "8096" ]]; then
            printf 'Azure/ARO-HCP#8096 is still open\n'
            return 0
        fi
    done <<<"${listing}"
}

# ---------------------------------------------------------------------------
# Publication gates that must run before any collection or commit
# ---------------------------------------------------------------------------
if [[ "${publish}" == true ]]; then
    load_github_token
    blocker=$(publication_blocker) || error "cannot evaluate the open pull request gate"
    if [[ -n "${blocker:-}" ]]; then
        log "[info] skipping publication: ${blocker}"
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Collect and score
# ---------------------------------------------------------------------------
for cred in client-id client-secret tenant; do
    [[ -r "${AZURE_CREDENTIALS_DIR}/${cred}" ]] ||
        error "azure credential file not found: ${AZURE_CREDENTIALS_DIR}/${cred}"
done
AZURE_CLIENT_ID=$(cat "${AZURE_CREDENTIALS_DIR}/client-id")
AZURE_CLIENT_SECRET=$(cat "${AZURE_CREDENTIALS_DIR}/client-secret")
AZURE_TENANT_ID=$(cat "${AZURE_CREDENTIALS_DIR}/tenant")
readonly AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
export AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
export AZURE_TOKEN_CREDENTIALS=prod

readonly SCORES="${ARTIFACT_DIR}/priority-scores.json"
readonly CHANGES="${ARTIFACT_DIR}/priority-changes.json"
readonly OBSERVATIONS="${PRIVATE_DIR}/observations-${build_id:-local}.json"

info "collecting ${PRIORITIES_LOOKBACK} of E2E results from ${KUSTO_CLUSTER}.${KUSTO_REGION}/${KUSTO_DATABASE}"
"${RUNNER}" priorities \
    --kusto "${KUSTO_CLUSTER}" \
    --region "${KUSTO_REGION}" \
    --database "${KUSTO_DATABASE}" \
    --job-filter e2e-parallel \
    --since "${PRIORITIES_LOOKBACK}" \
    --min-samples "${PRIORITIES_MIN_SAMPLES}" \
    --timeout 10m \
    --save-input "${OBSERVATIONS}" \
    --output json >"${SCORES}" || error "priority collection failed"

window_to=$(jq -r '.selection.to // empty' "${SCORES}") || error "cannot read the score window"
[[ -n "${window_to}" ]] || error "the score report has no selection window"
window_to_epoch=$(date -u -d "${window_to}" +%s) || error "cannot parse the score window end '${window_to}'"
jq -e '.quality.reason == null' "${SCORES}" >/dev/null ||
    error "the score report has no usable history: $(jq -r '.quality.reason // "unknown"' "${SCORES}")"
jq -e '.selection.job_filter == "e2e-parallel"' "${SCORES}" >/dev/null ||
    error "the score report does not use the configured job filter"

for environment in dev int stg prod; do
    builds=$(jq -r --arg env "${environment}" \
        '[.environments[]? | select(.environment == $env) | .eligible_build_count] | first // 0' "${SCORES}") ||
        error "cannot read ${environment} coverage"
    latest=$(jq -r --arg env "${environment}" \
        '[.environments[]? | select(.environment == $env) | .latest_eligible_completion] | first // empty' "${SCORES}") ||
        error "cannot read ${environment} freshness"
    if [[ -z "${latest}" ]]; then
        error "no eligible ${environment} builds in the report; refusing to refresh on partial coverage"
    fi
    if ((builds < PRIORITIES_MIN_SAMPLES)); then
        error "only ${builds} eligible ${environment} builds, need ${PRIORITIES_MIN_SAMPLES}; refusing to refresh"
    fi
    latest_epoch=$(date -u -d "${latest}" +%s) || error "cannot parse ${environment} freshness '${latest}'"
    if (((window_to_epoch - latest_epoch) > LOOKBACK_DAYS * 86400)); then
        error "the newest eligible ${environment} build finished at ${latest}, more than ${LOOKBACK_DAYS} days before the window end ${window_to}"
    fi
    info "coverage ${environment}: ${builds} eligible builds, latest ${latest}"
done

"${RUNNER}" list tests --output json >"${PRIVATE_DIR}/catalog-before.json" ||
    error "cannot list the before catalog"

refresh_args=(--report "${SCORES}" --catalog "${PRIVATE_DIR}/catalog-before.json" --repo "${REPO_DIR}")
if [[ "${publish}" == true ]]; then
    refresh_args+=(--write)
fi
"${RUNNER}" refresh-priorities "${refresh_args[@]}" >"${CHANGES}" ||
    error "priority refresh failed; no source or GitHub write was published"

changed_count=$(jq '.changes | length' "${CHANGES}") || error "cannot read the change summary"
info "planned ${changed_count} source changes"

if [[ "${publish}" != true ]]; then
    log "[info] read-only run finished; ${changed_count} proposed changes recorded in ${CHANGES}"
    exit 0
fi

if ((changed_count == 0)); then
    log "[info] no priority changes proposed; nothing to publish"
    exit 0
fi

# ---------------------------------------------------------------------------
# Verify the edited checkout before publishing anything
# ---------------------------------------------------------------------------
info "rebuilding the runner from the edited checkout"
(
    cd "${REPO_DIR}/test" &&
        go build -o "${PRIVATE_DIR}/aro-hcp-tests-after" ./cmd/aro-hcp-tests
) || error "cannot rebuild the E2E runner after the edits"

"${PRIVATE_DIR}/aro-hcp-tests-after" list tests --output json >"${PRIVATE_DIR}/catalog-after.json" ||
    error "cannot list the after catalog"

"${RUNNER}" refresh-priorities \
    --report "${SCORES}" \
    --catalog "${PRIVATE_DIR}/catalog-before.json" \
    --verify-catalog "${PRIVATE_DIR}/catalog-after.json" \
    --repo "${REPO_DIR}" >"${PRIVATE_DIR}/verify.json" 2>"${PRIVATE_DIR}/verify.err" ||
    error "the rebuilt catalog does not match the plan: $(cat "${PRIVATE_DIR}/verify.err")"
info "rebuilt catalog matches the plan"

readonly FIXTURE_DIR="${REPO_DIR}/test/testdata"
mkdir -p "${PRIVATE_DIR}/fixtures-before"
for fixture in "${FIXTURE_DIR}"/zz_fixture_TestMainListSuitesForEachSuite_*.txt; do
    sort "${fixture}" >"${PRIVATE_DIR}/fixtures-before/$(basename "${fixture}")"
done

info "regenerating the suite membership fixtures"
(
    cd "${REPO_DIR}/test" &&
        UPDATE=true go test -count=1 ./cmd/aro-hcp-tests -run '^TestMainListSuitesForEachSuite$'
) || error "suite fixture regeneration failed"

info "running the start-priority and suite checks"
(
    cd "${REPO_DIR}/test" &&
        go test -count=1 ./cmd/aro-hcp-tests -run '^(TestRegisteredSpecsDeclareValidStartPriority|TestStartPriorityDoesNotChangeSuiteMembership|TestMainListSuitesForEachSuite|TestOrderSpecsForStart.*|TestParseStartPriority.*)$' &&
        go test -count=1 ./util/labels
) || error "the start-priority or suite checks failed; refusing to publish"

# Every changed fixture must remain a permutation of its original: a priority
# refresh may only reorder a suite, never add or remove a spec.
mapfile -t fixture_paths < <(git -C "${REPO_DIR}" status --porcelain | awk '$4 ~ /^test\/testdata\/zz_fixture_TestMainListSuitesForEachSuite_/ {print $4}')
for fixture in "${fixture_paths[@]:-}"; do
    [[ -n "${fixture}" ]] || continue
    name=$(basename "${fixture}")
    [[ -f "${PRIVATE_DIR}/fixtures-before/${name}" ]] ||
        error "the refresh created an unexpected suite fixture ${fixture}"
    if ! diff -q <(sort "${REPO_DIR}/${fixture}") "${PRIVATE_DIR}/fixtures-before/${name}" >/dev/null; then
        error "suite fixture ${fixture} changed its spec membership, not only its order"
    fi
done

# ---------------------------------------------------------------------------
# Diff allowlist and commit
# ---------------------------------------------------------------------------
mapfile -t diff_paths < <(git -C "${REPO_DIR}" status --porcelain | cut -c4-)
if ((${#diff_paths[@]} == 0)); then
    log "[info] the verified checkout is unchanged; nothing to publish"
    exit 0
fi
for path in "${diff_paths[@]}"; do
    if [[ ! "${path}" =~ ^test/e2e/[A-Za-z0-9_./-]+\.go$ ]] &&
        [[ ! "${path}" =~ ^test/testdata/zz_fixture_TestMainListSuitesForEachSuite_[A-Za-z0-9_.-]+\.txt$ ]]; then
        error "unexpected change outside the refresh allowlist: ${path}"
    fi
done

git -C "${REPO_DIR}" add -- "${diff_paths[@]}" || error "cannot stage the refreshed files"
git -C "${REPO_DIR}" -c user.name="${GITHUB_BOT_NAME}" -c user.email="${GITHUB_BOT_EMAIL}" \
    commit --quiet --message "${TITLE}" || error "cannot commit the refresh"
commit_sha=$(git -C "${REPO_DIR}" rev-parse HEAD) || error "cannot resolve the refresh commit"
info "committed ${commit_sha}"

# ---------------------------------------------------------------------------
# Push and open the pull request
# ---------------------------------------------------------------------------
blocker=$(publication_blocker) || error "cannot re-evaluate the open pull request gate"
if [[ -n "${blocker:-}" ]]; then
    log "[info] not publishing: ${blocker}"
    exit 0
fi

branch="bot/test-priorities-${build_id}"
cat >"${PRIVATE_DIR}/askpass.sh" <<'ASKPASS'
#!/bin/bash
cat "${GITHUB_TOKEN_FILE}"
ASKPASS
chmod 700 "${PRIVATE_DIR}/askpass.sh"
export GIT_ASKPASS="${PRIVATE_DIR}/askpass.sh"
export GITHUB_TOKEN_FILE
export GIT_TERMINAL_PROMPT=0
unset GITHUB_TOKEN

info "pushing ${branch}"
if ! git -C "${REPO_DIR}" push \
    --force-with-lease="refs/heads/${branch}:" \
    "https://x-access-token@github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git" \
    "HEAD:refs/heads/${branch}" >"${PRIVATE_DIR}/push.log" 2>&1; then
    error "cannot create ${branch}: $(cat "${PRIVATE_DIR}/push.log")"
fi

mapfile -t env_rows < <(jq -r '.environments[]? | "| \(.environment) | \(.eligible_build_count) | \(.eligible_sample_count) | \(.median_minutes) | \(.latest_eligible_completion) |"' "${SCORES}")
mapfile -t change_rows < <(jq -r '.changes[]? | "| \(.name | gsub("\\|"; "\\|")) | \(.old_priority) | \(.new_priority) | \(.score_minutes) | \(.eligible_build_count) | \(.environments | join(", ")) |"' "${CHANGES}")
window_from=$(jq -r '.selection.from' "${SCORES}")
origin=$(jq -r '.selection.origin' "${SCORES}")
algorithm=$(jq -r '.algorithm' "${SCORES}")
global_median=$(jq -r '.global_median_minutes' "${SCORES}")

{
    echo "${MARKER}"
    echo
    echo "## What"
    echo
    echo "Refresh the \`labels.StartPriority\` declarations of the E2E suite from measured implementation durations."
    echo "This pull request was generated by ${SCHEDULED_JOB}; it changes no test logic, only start order."
    echo
    echo "## Why"
    echo
    echo "Start priority only exists so the suite scheduler starts the long specs early. Deriving it by hand drifts"
    echo "from reality, so it is recomputed from CI telemetry on a fixed schedule instead."
    echo
    echo "## Data"
    echo
    echo "- Kusto scope: \`${origin}\`"
    echo "- Completion window: \`${window_from}\` to \`${window_to}\` with job filter \`e2e-parallel\`"
    echo "- Algorithm: \`${algorithm}\` (minimum ${PRIORITIES_MIN_SAMPLES} distinct builds per spec and environment, global median ${global_median} minutes)"
    echo "- Only successful, processed runs and passed \`e2e\` results contribute; skipped, failed and unprocessed records never count as zero-duration samples."
    echo
    echo "| Environment | Eligible builds | Eligible samples | Median (min) | Latest eligible completion |"
    echo "| --- | --- | --- | --- | --- |"
    printf '%s\n' "${env_rows[@]}"
    echo
    echo "## Changed specs"
    echo
    echo "| Test | Old priority | New priority | Score (min) | Builds | Environments |"
    echo "| --- | --- | --- | --- | --- | --- |"
    printf '%s\n' "${change_rows[@]}"
    echo
    echo "## Testing"
    echo
    echo "- \`refresh-priorities\` mapped every proposal to one exact source declaration; no regex rewrite."
    echo "- The E2E runner was rebuilt from this commit, the catalog was regenerated and verified to keep every spec name, keep all labels other than \`StartPriority\` unchanged, and carry exactly the proposed priorities."
    echo "- \`TestRegisteredSpecsDeclareValidStartPriority\`, \`TestStartPriorityDoesNotChangeSuiteMembership\` and the suite ordering and parsing tests pass."
    echo "- Each regenerated suite fixture is a permutation of its original; no suite gained or lost a spec."
    echo "- No live E2E run was executed for a label refresh."
    echo
    echo "## Notes for the reviewer"
    echo
    echo "- The diff is limited to \`test/e2e/**/*.go\` and \`test/testdata/zz_fixture_TestMainListSuitesForEachSuite_*.txt\`."
    echo "- Base commit: \`${base_sha}\`."
    echo "- Job: ${job_url:-unknown}"
    echo "- Kindly review the priority deltas above; this pull request is never merged automatically."
    echo
    echo "---"
    echo "Generated by ${SCHEDULED_JOB} (build ${build_id}). Re-running the job while this pull request is open is a no-op."
} >"${PRIVATE_DIR}/body.md"

jq -n --arg head "${branch}" --arg base "${GITHUB_BASE_BRANCH}" --arg title "${TITLE}" \
    --rawfile body "${PRIVATE_DIR}/body.md" \
    '{head: $head, base: $base, title: $title, body: $body}' >"${PRIVATE_DIR}/pull.json"

created=$(curl --config "${CURL_CONFIG}" -X POST --data @"${PRIVATE_DIR}/pull.json" \
    "${API}/repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/pulls") ||
    error "pushed ${branch} at ${commit_sha} but creating the pull request failed; the branch was left in place for inspection"
number=$(jq -r '.number // empty' <<<"${created}") || error "cannot read the created pull request"
[[ -n "${number}" ]] || error "pushed ${branch} at ${commit_sha} but the pull request response had no number"

# ---------------------------------------------------------------------------
# Verify the published pull request
# ---------------------------------------------------------------------------
published=$(github_get "repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/pulls/${number}") ||
    error "cannot re-read the created pull request #${number}"
files=$(github_get "repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/pulls/${number}/files?per_page=100") ||
    error "cannot list the files of pull request #${number}"

[[ "$(jq -r '.user.login' <<<"${published}")" == "${GITHUB_BOT_LOGIN}" ]] || error "pull request #${number} is not authored by ${GITHUB_BOT_LOGIN}"
[[ "$(jq -r '.base.ref' <<<"${published}")" == "${GITHUB_BASE_BRANCH}" ]] || error "pull request #${number} does not target ${GITHUB_BASE_BRANCH}"
[[ "$(jq -r '.title' <<<"${published}")" == "${TITLE}" ]] || error "pull request #${number} has an unexpected title"
[[ "$(jq -r '.head.sha' <<<"${published}")" == "${commit_sha}" ]] || error "pull request #${number} does not point at ${commit_sha}"
jq -r '.body // empty' <<<"${published}" | grep -Fq "${MARKER}" || error "pull request #${number} lost its marker"

for file in $(jq -r '.[].filename' <<<"${files}"); do
    if [[ ! "${file}" =~ ^test/e2e/[A-Za-z0-9_./-]+\.go$ ]] &&
        [[ ! "${file}" =~ ^test/testdata/zz_fixture_TestMainListSuitesForEachSuite_[A-Za-z0-9_.-]+\.txt$ ]]; then
        error "pull request #${number} contains ${file}, outside the refresh allowlist"
    fi
done

log "[info] opened pull request #${number}: $(jq -r '.html_url' <<<"${published}")"
exit 0
