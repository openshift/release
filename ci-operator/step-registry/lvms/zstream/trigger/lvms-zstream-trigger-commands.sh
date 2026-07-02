#!/usr/bin/bash
set -euo pipefail

# Trigger LVMS z-stream e2e tests via Gangway API.
#
# For each configured release, checks GitHub for open z-stream PRs on
# openshift/lvm-operator, resolves the catalog image digest from the PR
# diff via the quay.io API, and triggers existing nightly e2e jobs with
# MULTISTAGE_PARAM_OVERRIDE_LVM_INDEX_IMAGE set to the resolved digest.
#
# Skips releases with no open PR or where the digest hasn't changed since
# the last run (tracked via a state file).

RELEASES="4.14,4.16,4.18,4.19,4.20,4.21"
DRY_RUN=false
FORCE=false
WORKDIR="${ARTIFACT_DIR}/zstream"
TOKEN_FILE="/etc/gangway/token"

GANGWAY_API="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com"
GITHUB_API="https://api.github.com"
QUAY_API="https://quay.io/api/v1"
QUAY_REPO="redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog"
TRIGGER_JOB_NAME="periodic-ci-openshift-lvm-operator-main-zstream-trigger"
GCS_BUCKET="test-platform-results"
PREV_SUMMARY=""

NIGHTLY_JOBS=(
    "e2e-aws-sno-qe-integration-tests"
    "e2e-aws-sno-arm-qe-integration-tests"
    "e2e-aws-mno-qe-integration-tests"
    "e2e-aws-mno-arm-qe-integration-tests"
    "e2e-baremetalds-sno-dualstack-qe-integration-tests"
    "e2e-baremetalds-mno-dualstack-qe-integration-tests"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date +%H:%M:%S)] $*" >&2; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

github_curl() {
    local -a headers=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    curl -sSL --connect-timeout 10 --max-time 30 "${headers[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Read token
# ---------------------------------------------------------------------------

if [[ -f "${TOKEN_FILE}" ]]; then
    MY_APPCI_TOKEN=$(cat "${TOKEN_FILE}")
else
    err "Token file not found: ${TOKEN_FILE}"
    exit 1
fi

mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# State management — compare digest with previous CI run's artifacts in GCS
# ---------------------------------------------------------------------------

load_previous_summary() {
    local prev_build_id
    prev_build_id=$(curl -sSL --connect-timeout 10 --max-time 30 \
        "https://prow.ci.openshift.org/prowjobs.js?omit=annotations,labels,decoration_config,pod_spec&job=${TRIGGER_JOB_NAME}" 2>/dev/null \
        | sed 's/^var allBuilds = //; s/;$//' \
        | jq -r '[.items[] | select(.status.state == "success")] | sort_by(.status.completionTime) | last | .status.build_id // empty' 2>/dev/null || true)

    if [[ -z "${prev_build_id}" ]]; then
        info "No previous successful run found — will trigger all releases"
        PREV_SUMMARY=""
        return
    fi

    info "Previous successful run: ${prev_build_id}"
    local gcs_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/${GCS_BUCKET}/logs/${TRIGGER_JOB_NAME}/${prev_build_id}/artifacts/${TRIGGER_JOB_NAME}/trigger/artifacts/zstream/zstream-summary.json"
    local tmp_file
    tmp_file=$(mktemp)

    if curl -sSL --connect-timeout 10 --max-time 30 -o "${tmp_file}" "${gcs_url}" 2>/dev/null && jq empty "${tmp_file}" 2>/dev/null; then
        PREV_SUMMARY="${tmp_file}"
        info "Loaded previous summary from GCS"
    else
        info "Could not fetch previous summary from GCS — will trigger all releases"
        rm -f "${tmp_file}"
        PREV_SUMMARY=""
    fi
}

get_last_digest() {
    local release="$1"
    if [[ -z "${PREV_SUMMARY}" ]]; then
        echo ""
        return
    fi
    jq -r --arg r "${release}" '.[$r].image // "" | split("@") | if length > 1 then .[1] else "" end' "${PREV_SUMMARY}" 2>/dev/null || echo ""
}

get_last_pr() {
    local release="$1"
    if [[ -z "${PREV_SUMMARY}" ]]; then
        echo ""
        return
    fi
    jq -r --arg r "${release}" '.[$r].pr // "" | ltrimstr("#")' "${PREV_SUMMARY}" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# GitHub: find open z-stream PR for a release
# ---------------------------------------------------------------------------

find_zstream_pr() {
    local release="$1"
    local major minor
    major=$(echo "${release}" | cut -d. -f1)
    minor=$(echo "${release}" | cut -d. -f2)

    local prs_json
    prs_json=$(github_curl "${GITHUB_API}/repos/openshift/lvm-operator/pulls?state=open&per_page=100")

    echo "${prs_json}" | jq -r --arg maj "${major}" --arg min "${minor}" '
        [.[] | select(.title | test(": Release " + $maj + "\\." + $min + "\\."; "i"))] |
        if length > 0 then .[0] else empty end |
        [.number, .title] | @tsv
    '
}

# ---------------------------------------------------------------------------
# GitHub: check if a previously tracked PR was merged
# ---------------------------------------------------------------------------

check_pr_merged() {
    local pr_number="$1"
    local pr_json
    pr_json=$(github_curl "${GITHUB_API}/repos/openshift/lvm-operator/pulls/${pr_number}")

    local state merged_at
    state=$(echo "${pr_json}" | jq -r '.state // ""')
    merged_at=$(echo "${pr_json}" | jq -r '.merged_at // ""')

    if [[ "${state}" == "closed" && -n "${merged_at}" && "${merged_at}" != "null" ]]; then
        echo "merged"
    fi
}

# ---------------------------------------------------------------------------
# GitHub: extract snapshot name from PR diff
# ---------------------------------------------------------------------------

extract_snapshot() {
    local pr_number="$1"

    local files_json
    files_json=$(github_curl "${GITHUB_API}/repos/openshift/lvm-operator/pulls/${pr_number}/files")

    echo "${files_json}" | jq -r '
        [.[] | select(.filename | contains("catalog")) | .patch // ""] |
        join("\n")
    ' | grep -oP '(?<=snapshot: )\S+' | head -1
}

# ---------------------------------------------------------------------------
# Quay: resolve snapshot to digest
# ---------------------------------------------------------------------------

resolve_snapshot_to_digest() {
    local snapshot="$1"

    local version_prefix date_str time_str
    version_prefix=$(echo "${snapshot}" | grep -oP 'lvm-operator-catalog-\d+-\d+')
    date_str=$(echo "${snapshot}" | grep -oP '\d{8}(?=-\d{6}-)')
    time_str=$(echo "${snapshot}" | grep -oP '(?<=\d{8}-)\d{6}')

    if [[ -z "${version_prefix}" || -z "${date_str}" || -z "${time_str}" ]]; then
        err "Cannot parse snapshot name: ${snapshot}"
        return 1
    fi

    local snap_year snap_month snap_day snap_hour snap_min snap_sec snap_epoch
    snap_year=${date_str:0:4}
    snap_month=${date_str:4:2}
    snap_day=${date_str:6:2}
    snap_hour=${time_str:0:2}
    snap_min=${time_str:2:2}
    snap_sec=${time_str:4:2}
    snap_epoch=$(date -d "${snap_year}-${snap_month}-${snap_day}T${snap_hour}:${snap_min}:${snap_sec}Z" +%s 2>/dev/null || echo 0)

    # Convert version prefix (lvm-operator-catalog-4-16) to v4.16 for tag matching
    local version_dot
    version_dot=$(echo "${version_prefix}" | sed 's/lvm-operator-catalog-//; s/-/./')

    # Query quay for v{version} commit tags (not -on-push, which expire)
    local tags_json
    tags_json=$(curl -sSL --connect-timeout 10 --max-time 30 \
        "${QUAY_API}/repository/${QUAY_REPO}/tag/?limit=50&filter_tag_name=like:v${version_dot}-")

    # Select only raw commit tags (v4.16-{40-hex}), exclude auxiliary suffixes
    # Pick the closest one after the snapshot timestamp (smallest positive delta)
    local result
    result=$(echo "${tags_json}" | jq -r --arg snap_epoch "${snap_epoch}" --arg vpfx "v${version_dot}-" '
        [.tags[]
         | select(.name | startswith($vpfx))
         | select(.name | test("^v[0-9]+\\.[0-9]+-[a-f0-9]{40}$"))
         | .tag_epoch = (.last_modified | strptime("%a, %d %b %Y %H:%M:%S %z") | mktime)
         | .delta = (.tag_epoch - ($snap_epoch | tonumber))
         | select(.delta >= 0 and .delta < 1800)
        ] | sort_by(.delta) | .[0] // empty |
        [.name, .manifest_digest] | @tsv
    ')

    if [[ -z "${result}" ]]; then
        err "No matching quay tag found for snapshot ${snapshot}"
        return 1
    fi

    local tag_name digest
    tag_name=$(echo "${result}" | cut -f1)
    digest=$(echo "${result}" | cut -f2)

    info "Resolved: ${snapshot} → ${tag_name} (${digest})"
    echo "${digest}"
}

# ---------------------------------------------------------------------------
# Gangway: trigger a nightly job with image override
# ---------------------------------------------------------------------------

trigger_job() {
    local job_name="$1" image="$2"

    local body
    body=$(jq -cn \
        --arg img "${image}" \
        '{job_execution_type: "1", pod_spec_options: {envs: {MULTISTAGE_PARAM_OVERRIDE_LVM_INDEX_IMAGE: $img}}}')

    if ${DRY_RUN}; then
        info "[dry-run] would trigger: ${job_name}"
        info "[dry-run]   image: ${image}"
        return 0
    fi

    local http_code
    [[ $- == *x* ]] && local _was_tracing=true || local _was_tracing=false
    set +x
    http_code=$(curl -sSL -X POST -o /dev/stderr -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -H "Authorization: Bearer ${MY_APPCI_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "${GANGWAY_API}/v1/executions/${job_name}" 2>/dev/null)
    $_was_tracing && set -x

    if [[ "${http_code}" == "200" ]]; then
        info "  triggered: ${job_name}"
        return 0
    else
        warn "  failed (HTTP ${http_code}): ${job_name}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Prow: fetch latest run results for nightly jobs
# ---------------------------------------------------------------------------

fetch_last_runs() {
    local release="$1"
    local job_prefix="periodic-ci-openshift-lvm-operator-release-${release}-nightly-"
    local results="[]"

    for test_name in "${NIGHTLY_JOBS[@]}"; do
        local full_job="${job_prefix}${test_name}"
        local prow_json
        prow_json=$(curl -sSL --connect-timeout 10 --max-time 30 \
            "https://prow.ci.openshift.org/prowjobs.js?omit=annotations,labels,decoration_config,pod_spec&job=${full_job}" 2>/dev/null || true)

        if [[ -z "${prow_json}" ]]; then
            results=$(echo "${results}" | jq --arg n "${test_name}" '. + [{name: $n, state: "unknown"}]')
            continue
        fi

        local entry
        entry=$(echo "${prow_json}" | sed 's/^var allBuilds = //' | \
            jq -r --arg n "${test_name}" '
                [.items[] | select(.status.state == "success" or .status.state == "failure" or .status.state == "error" or .status.state == "aborted")] |
                sort_by(.status.startTime) | reverse |
                if length > 0 then .[0] else null end |
                if . then {name: $n, state: .status.state, url: .status.url, started: .status.startTime} else {name: $n, state: "unknown"} end
            ' 2>/dev/null || echo "{\"name\": \"${test_name}\", \"state\": \"unknown\"}")

        results=$(echo "${results}" | jq --argjson e "${entry}" '. + [$e]')
    done

    echo "${results}"
}

# ---------------------------------------------------------------------------
# Process a single release
# ---------------------------------------------------------------------------

process_release() {
    local release="$1"

    info "--- Release ${release} ---"

    # Find open z-stream PR
    local pr_info
    pr_info=$(find_zstream_pr "${release}" || true)

    if [[ -z "${pr_info}" ]]; then
        # Check if a previously tracked PR was merged
        local last_pr
        last_pr=$(get_last_pr "${release}")
        if [[ -n "${last_pr}" ]]; then
            local merge_status
            merge_status=$(check_pr_merged "${last_pr}" || true)
            if [[ "${merge_status}" == "merged" ]]; then
                info "PR #${last_pr} was merged for ${release}."
                jq -n --arg r "${release}" --arg pr "${last_pr}" \
                    '{($r): {status: "completed", reason: "release completed", pr: ("#" + $pr)}}' \
                    > "${WORKDIR}/zstream-${release}.json"
                return 0
            fi
        fi

        info "No z-stream release PR found for ${release}."
        jq -n --arg r "${release}" \
            '{($r): {status: "no_pr", reason: "no new releases"}}' \
            > "${WORKDIR}/zstream-${release}.json"
        return 0
    fi

    local pr_number pr_title
    pr_number=$(echo "${pr_info}" | cut -f1)
    pr_title=$(echo "${pr_info}" | cut -f2)
    info "Found PR #${pr_number}: ${pr_title}"

    # Extract snapshot from PR
    local snapshot
    snapshot=$(extract_snapshot "${pr_number}")

    if [[ -z "${snapshot}" ]]; then
        warn "Could not extract catalog snapshot from PR #${pr_number}"
        jq -n --arg r "${release}" --arg pr "${pr_number}" \
            '{($r): {status: "error", reason: "no snapshot in PR", pr: ("#" + $pr)}}' \
            > "${WORKDIR}/zstream-${release}.json"
        return 0
    fi

    info "Snapshot: ${snapshot}"

    # Resolve to digest
    local digest
    digest=$(resolve_snapshot_to_digest "${snapshot}" || true)

    if [[ -z "${digest}" ]]; then
        warn "Could not resolve snapshot to digest for ${release}"
        jq -n --arg r "${release}" --arg pr "${pr_number}" --arg snap "${snapshot}" \
            '{($r): {status: "error", reason: "digest resolution failed", pr: ("#" + $pr), snapshot: $snap}}' \
            > "${WORKDIR}/zstream-${release}.json"
        return 0
    fi

    local image="quay.io/${QUAY_REPO}@${digest}"

    # Check if already tested
    if ! ${FORCE}; then
        local last_digest
        last_digest=$(get_last_digest "${release}")
        if [[ "${last_digest}" == "${digest}" ]]; then
            info "Already tested with same digest. Fetching last run results."
            local last_runs
            last_runs=$(fetch_last_runs "${release}")
            jq -n --arg r "${release}" --arg pr "${pr_number}" --arg title "${pr_title}" --arg img "${image}" --arg snap "${snapshot}" \
                --argjson jobs "${last_runs}" \
                '{($r): {status: "skipped", reason: "same digest", pr: ("#" + $pr), pr_title: $title, image: $img, snapshot: $snap, jobs: $jobs}}' \
                > "${WORKDIR}/zstream-${release}.json"
            return 0
        fi
    fi

    # Trigger nightly jobs
    local job_prefix="periodic-ci-openshift-lvm-operator-release-${release}-nightly-"
    local triggered=0 failed=0
    local triggered_jobs=()

    for test_name in "${NIGHTLY_JOBS[@]}"; do
        local full_job="${job_prefix}${test_name}"
        if trigger_job "${full_job}" "${image}"; then
            triggered=$((triggered + 1))
            triggered_jobs+=("${full_job}")
        else
            failed=$((failed + 1))
        fi
        ${DRY_RUN} || sleep 5
    done

    info "${release}: ${triggered} triggered, ${failed} failed"

    # Write per-release summary
    jq -n \
        --arg r "${release}" \
        --arg pr "${pr_number}" \
        --arg title "${pr_title}" \
        --arg img "${image}" \
        --arg snap "${snapshot}" \
        --argjson triggered "${triggered}" \
        --argjson failed "${failed}" \
        --argjson jobs "$(if [[ ${#triggered_jobs[@]} -gt 0 ]]; then printf '%s\n' "${triggered_jobs[@]}" | jq -R . | jq -s .; else echo '[]'; fi)" \
        '{($r): {status: "triggered", pr: ("#" + $pr), pr_title: $title, image: $img, snapshot: $snap, jobs_triggered: $triggered, jobs_failed: $failed, jobs: $jobs}}' \
        > "${WORKDIR}/zstream-${release}.json"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "=== LVMS Z-Stream Trigger ==="
    info "Releases: ${RELEASES}"
    info "Workdir:  ${WORKDIR}"
    ${DRY_RUN} && info "Mode: DRY RUN"
    ${FORCE} && info "Mode: FORCE (ignoring last-tested digest)"

    load_previous_summary

    IFS=',' read -ra release_list <<< "${RELEASES}"

    for release in "${release_list[@]}"; do
        release=$(echo "${release}" | xargs)
        process_release "${release}"
    done

    # Merge per-release summaries into one file
    local summary_file="${WORKDIR}/zstream-summary.json"
    jq -s 'add' "${WORKDIR}"/zstream-*.json > "${summary_file}" 2>/dev/null || echo '{}' > "${summary_file}"

    # Print summary
    info ""
    info "=== Summary ==="
    jq -r 'to_entries[] | "  \(.key): \(.value.status)\(if .value.reason then " (\(.value.reason))" elif .value.jobs_triggered then " (\(.value.jobs_triggered) jobs)" else "" end)"' \
        "${summary_file}" >&2

    # Cleanup
    [[ -n "${PREV_SUMMARY}" ]] && rm -f "${PREV_SUMMARY}"

    info ""
    info "Summary written to: ${summary_file}"
}

main
