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
readonly LOOKBACK_DAYS=7

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
rehearsal=false
case "${job_name}" in
rehearse-*) rehearsal=true ;;
esac

# Publication is limited to the scheduled job, or to a rehearsal of it that
# explicitly opts in. A rehearsal arrives as a presubmit ProwJob whose name keeps
# the scheduled job as a suffix, so the type alone cannot decide this.
if [[ "${job_name}" != *"${SCHEDULED_JOB}" ]]; then
    info "job ${job_name} is not the scheduled ${SCHEDULED_JOB}: forcing read-only behaviour"
    publish=false
fi
if [[ "${rehearsal}" == true ]]; then
    # The opt-in exists to prove the publication path once; the merged
    # configuration never sets it, so rehearsals stay read-only by default.
    if [[ "${PRIORITIES_REHEARSAL_PUBLISH:-false}" != true ]]; then
        info "rehearsal ${job_name}: forcing read-only behaviour"
        publish=false
    fi
elif [[ "${job_type}" != periodic ]]; then
    info "job ${job_name} (${job_type}) is not a periodic: forcing read-only behaviour"
    publish=false
fi
if [[ "${publish}" == true ]]; then
    [[ "${build_id}" =~ ^[0-9]+$ ]] || error "publication requires a numeric Prow build ID, got '${build_id}'"
fi
info "job ${job_name} (${job_type}), build ${build_id}, publication ${publish}"

[[ -n "${ARTIFACT_DIR:-}" ]] || error "ARTIFACT_DIR is required"
[[ "${PRIORITIES_MIN_SAMPLES}" =~ ^[0-9]+$ ]] ||
    error "PRIORITIES_MIN_SAMPLES must be a number, got '${PRIORITIES_MIN_SAMPLES}'"

for tool in git jq go; do
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
# Publication gate that must run before any collection or commit
# ---------------------------------------------------------------------------
readonly BOT_BRANCH_PREFIX='bot/test-priorities-'

# publication_gate reports whether this run may publish, as one JSON object.
publication_gate() {
    "${RUNNER}" priorities-gate \
        --repo "${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}" \
        --base "${GITHUB_BASE_BRANCH}" \
        --base-commit "${base_sha}" \
        --actor "${GITHUB_BOT_LOGIN}" \
        --marker "${MARKER}" \
        --branch-prefix "${BOT_BRANCH_PREFIX}" \
        --token-path "${GITHUB_TOKEN_PATH}"
}

if [[ "${publish}" == true ]]; then
    [[ -r "${GITHUB_TOKEN_PATH}" ]] ||
        error "publication requires the GitHub App token at ${GITHUB_TOKEN_PATH}"
    gate=$(publication_gate) || error "cannot evaluate the publication gate"
    blocker=$(jq -r '.reason // empty' <<<"${gate}") || error "cannot read the gate result"
    if [[ -n "${blocker}" ]]; then
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
# Re-check the gate before the expensive rebuild: the token may have expired and
# another run may have opened a proposal while this one was collecting.
gate=$(publication_gate) || error "cannot re-evaluate the publication gate"
blocker=$(jq -r '.reason // empty' <<<"${gate}") || error "cannot read the gate result"
if [[ -n "${blocker}" ]]; then
    log "[info] not publishing: ${blocker}"
    exit 0
fi
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

# The published change set is the plan plus the suite fixtures it regenerated:
# the fixtures are derived, so they are not in the planner summary, but CI
# regenerates them and a pull request without them fails the suite test.
readonly PUBLISH_CHANGES="${PRIVATE_DIR}/changes-with-fixtures.json"
fixture_json=$(printf '%s\n' "${fixture_paths[@]:-}" | jq -R 'select(length > 0)' | jq -s 'map({path: .})') ||
    error "cannot encode the suite fixtures"
jq --argjson fixtures "${fixture_json}" '.changes += $fixtures' "${CHANGES}" >"${PUBLISH_CHANGES}" ||
    error "cannot extend the change summary with the suite fixtures"

# ---------------------------------------------------------------------------
# Report body
# ---------------------------------------------------------------------------
"${RUNNER}" priorities-summary \
    --report "${SCORES}" \
    --changes "${CHANGES}" \
    --note "Publication in progress." \
    --output "${PRIVATE_DIR}/summary-before.html" \
    --publication-body "${PRIVATE_DIR}/body.md" \
    --job-name "${job_name}" \
    --build-id "${build_id}" \
    --job-url "${job_url}" \
    --base-commit "${base_sha}" >/dev/null ||
    error "cannot render the pull request body"

# ---------------------------------------------------------------------------
# Commit, push and publish through the test CLI
# ---------------------------------------------------------------------------
info "publishing the refresh"
receipt=$("${RUNNER}" priorities-publish \
    --repo "${REPO_DIR}" \
    --base "${GITHUB_BASE_BRANCH}" \
    --head-repo "${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}" \
    --branch "${BOT_BRANCH_PREFIX}${build_id}" \
    --title "${TITLE}" \
    --body-file "${PRIVATE_DIR}/body.md" \
    --marker "${MARKER}" \
    --changes "${PUBLISH_CHANGES}" \
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
