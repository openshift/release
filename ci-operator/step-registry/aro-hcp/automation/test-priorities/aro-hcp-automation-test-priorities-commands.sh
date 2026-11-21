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
readonly SCHEDULED_JOB='periodic-ci-Azure-ARO-HCP-main-e2e-test-priorities-refresh'
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
SHARED_DIR=${SHARED_DIR:-}
GITHUB_TOKEN_PATH="${SHARED_DIR}/github-token"

# Diagnostics always go to stderr so captured command output stays data only.
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${*}" >&2; }
info() { if [[ ${VERBOSITY} -ge 1 ]]; then log "[info] ${*}"; fi; }
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
build_id=$(jq -r '.buildid // empty' <<<"${JOB_SPEC}") || error "cannot read JOB_SPEC.buildid"

# JOB_SPEC carries no run URL, so derive the periodic artifact link from the job
# name and build ID. That page holds the score and change artifacts a reviewer needs.
job_url=""
if [[ "${job_type}" == "periodic" && "${build_id}" =~ ^[0-9]+$ ]]; then
    job_url="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${job_name}/${build_id}"
fi

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

[[ -n "${ARTIFACT_DIR:-}" ]] || error "ARTIFACT_DIR is required"
[[ "${PRIORITIES_MIN_SAMPLES}" =~ ^[0-9]+$ ]] ||
    error "PRIORITIES_MIN_SAMPLES must be a number, got '${PRIORITIES_MIN_SAMPLES}'"

for tool in git curl jq go; do
    command -v "${tool}" >/dev/null 2>&1 || error "required tool '${tool}' is not installed"
done

# ---------------------------------------------------------------------------
# Trusted checkout: derive a clean tree from the baked repository's HEAD
# ---------------------------------------------------------------------------
readonly REPO_DIR="${PRIVATE_DIR}/aro-hcp"

# repo_git runs git inside the private checkout.
repo_git() { git -C "${REPO_DIR}" "$@"; }
[[ -d "${BAKED_REPO}/.git" ]] || error "${BAKED_REPO} is not a git checkout"
# The E2E image compiles its binaries inside this checkout, so its working tree
# carries untracked build output. Only the committed HEAD is ever published, so
# derive the refresh tree from that commit and ignore the local artifacts.
base_sha=$(git -C "${BAKED_REPO}" rev-parse HEAD) || error "cannot resolve the baked HEAD"
info "baked checkout HEAD is ${base_sha}"

git clone --quiet --no-hardlinks "${BAKED_REPO}" "${REPO_DIR}" || error "cannot copy the baked checkout"
repo_git checkout --quiet --detach "${base_sha}" || error "cannot check out ${base_sha}"
repo_git remote remove origin || error "cannot detach the private checkout from ${BAKED_REPO}"
[[ "$(repo_git rev-parse HEAD)" == "${base_sha}" ]] || error "the private checkout is not at ${base_sha}"
[[ -z "$(repo_git status --porcelain)" ]] || error "the private checkout is not clean"
info "working checkout ${REPO_DIR} at ${base_sha}"

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
load_github_token() {
    [[ -r "${GITHUB_TOKEN_PATH}" ]] ||
        error "publication requires the GitHub App token at ${GITHUB_TOKEN_PATH}"
}

github_get() {
    curl --silent --show-error --fail-with-body \
        --header "Authorization: Bearer $(<"${GITHUB_TOKEN_PATH}")" \
        --header 'Accept: application/vnd.github+json' \
        "${API}/$1"
}

# require_valid_token fails fast when the installation token has expired before
# the expensive rebuild, instead of losing the whole run at the final push.
require_valid_token() {
    github_get "rate_limit" >/dev/null 2>&1 ||
        error "the GitHub App token is no longer valid; publication needs a token minted for this run"
}

# require_base_is_ancestor fails when the baked commit is not part of the target
# branch, so a stale or foreign image can never publish an unrelated diff.
require_base_is_ancestor() {
    local compare status
    compare=$(github_get "repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/compare/${base_sha}...${GITHUB_BASE_BRANCH}") ||
        return 1
    status=$(jq -r '.status // empty' <<<"${compare}") || return 1
    case "${status}" in
    ahead | identical) return 0 ;;
    *)
        error "the baked commit ${base_sha} is not on ${GITHUB_BASE_BRANCH} (compare status ${status:-unknown})"
        ;;
    esac
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
        "${RUNNER}" priorities-summary --note "Publication skipped before collection: ${blocker}." \
            --output "${ARTIFACT_DIR}/priorities-summary.html" >/dev/null ||
            error "cannot write the run summary"
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

info "collecting ${PRIORITIES_LOOKBACK} of E2E results from ${KUSTO_CLUSTER}.${KUSTO_REGION}/${KUSTO_DATABASE}"
# One command collects, scores, enforces coverage and plans against this
# checkout. The catalog is listed first because verification below compares the
# rebuilt catalog against it.
"${RUNNER}" list tests --output json >"${PRIVATE_DIR}/catalog-before.json" ||
    error "cannot list the before catalog"

run_args=(--kusto "${KUSTO_CLUSTER}" --region "${KUSTO_REGION}" --database "${KUSTO_DATABASE}"
    --since "${PRIORITIES_LOOKBACK}" --job-filter e2e-parallel
    --min-samples "${PRIORITIES_MIN_SAMPLES}" --timeout 10m
    --repo "${REPO_DIR}" --artifact-dir "${ARTIFACT_DIR}" --max-age "$((LOOKBACK_DAYS * 24))h")
if [[ "${publish}" == true ]]; then
    run_args+=(--write)
fi
"${RUNNER}" priorities-run "${run_args[@]}" ||
    error "the priority refresh failed; no source or GitHub write was published"

changed_count=$(jq '.changes | length' "${CHANGES}") || error "cannot read the change summary"
info "planned ${changed_count} source changes"

if [[ "${publish}" != true ]]; then
    "${RUNNER}" priorities-summary --report "${SCORES}" --changes "${CHANGES}" \
        --note "Read-only run: the proposals above were recorded and nothing was written to the repository or to GitHub." \
        --output "${ARTIFACT_DIR}/priorities-summary.html" >/dev/null ||
        error "cannot write the run summary"
    log "[info] read-only run finished; ${changed_count} proposed changes recorded in ${CHANGES}"
    exit 0
fi

if ((changed_count == 0)); then
    if [[ -n "$(repo_git status --porcelain)" ]]; then
        error "the refresh reported no proposals but the checkout changed; refusing to continue"
    fi
    "${RUNNER}" priorities-summary --report "${SCORES}" --changes "${CHANGES}" \
        --note "No priority change is proposed, so nothing was published." \
        --output "${ARTIFACT_DIR}/priorities-summary.html" >/dev/null ||
        error "cannot write the run summary"
    log "[info] no priority changes proposed; nothing to publish"
    exit 0
fi

# ---------------------------------------------------------------------------
# Verify the edited checkout before publishing anything
# ---------------------------------------------------------------------------
require_valid_token
require_base_is_ancestor
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
mapfile -t fixture_paths < <(repo_git status --porcelain | cut -c4- |
    grep -E '^test/testdata/zz_fixture_TestMainListSuitesForEachSuite_[A-Za-z0-9_.-]+\.txt$' || true)
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
# Diff allowlist
# ---------------------------------------------------------------------------
mapfile -t diff_paths < <(repo_git status --porcelain | cut -c4-)
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

# ---------------------------------------------------------------------------
# Report body
# ---------------------------------------------------------------------------
mapfile -t env_rows < <(jq -r '.environments[]? | "| \(.environment) | \(.eligible_build_count) | \(.eligible_sample_count) | \(.median_minutes) | \(.latest_eligible_completion) |"' "${SCORES}")
mapfile -t change_rows < <(jq -r '.changes[]? | "| \(.name | gsub("\\|"; "\\|")) | \(.old_priority) | \(.new_priority) | \(.score_minutes) | \(.eligible_build_count) | \(.environments | join(", ")) |"' "${CHANGES}")
window_from=$(jq -r '.selection.from' "${SCORES}") || error "cannot read the score window start"
window_to=$(jq -r '.selection.to' "${SCORES}") || error "cannot read the score window end"
origin=$(jq -r '.selection.origin' "${SCORES}")
algorithm=$(jq -r '.algorithm' "${SCORES}")
global_median=$(jq -r '.global_median_minutes' "${SCORES}")

{
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

# ---------------------------------------------------------------------------
# Commit, push and publish through the test CLI
# ---------------------------------------------------------------------------
blocker=$(publication_blocker) || error "cannot re-evaluate the open pull request gate"
if [[ -n "${blocker:-}" ]]; then
    log "[info] not publishing: ${blocker}"
    exit 0
fi

info "publishing the refresh"
receipt=$("${RUNNER}" priorities-publish \
    --repo "${REPO_DIR}" \
    --base "${GITHUB_BASE_BRANCH}" \
    --head-repo "${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}" \
    --branch "bot/test-priorities-${build_id}" \
    --title "${TITLE}" \
    --body-file "${PRIVATE_DIR}/body.md" \
    --marker "${MARKER}" \
    --changes "${CHANGES}" \
    --git-name "${GITHUB_BOT_NAME}" \
    --git-email "${GITHUB_BOT_EMAIL}" \
    --actor "${GITHUB_BOT_LOGIN}" \
    --token-path "${GITHUB_TOKEN_PATH}") ||
    error "publishing the refresh failed; inspect the branch and pull request before retrying"

number=$(jq -r '.Number // empty' <<<"${receipt}") || error "cannot read the publication receipt"
pull_url=$(jq -r '.URL // empty' <<<"${receipt}") || error "cannot read the publication URL"
[[ -n "${number}" && -n "${pull_url}" ]] || error "the publication receipt is incomplete: ${receipt}"
"${RUNNER}" priorities-summary --report "${SCORES}" --changes "${CHANGES}" \
    --note "Published pull request #${number}." \
    --publication-url "${pull_url}" \
    --output "${ARTIFACT_DIR}/priorities-summary.html" >/dev/null ||
    error "pull request #${number} was created but the run summary could not be written"
log "[info] opened pull request #${number}: ${pull_url}"
exit 0
