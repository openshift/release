#!/bin/bash
#
# Identifies GitHub repositories referenced in this repo's CI configuration
# that have been archived or deleted on GitHub.
#
# Usage:
#   hack/find-archived-repos.sh [--json]
#   hack/find-archived-repos.sh --app-id=ID --app-key=PATH [--json]
#
# Without --app-id/--app-key, uses the gh CLI with whatever auth is configured.
# With --app-id/--app-key, authenticates as a GitHub App to get per-org
# installation tokens (higher rate limits, broader org access).
#
# To get the GitHub App credentials from the app.ci cluster:
#   oc --context app.ci -n ci get secret openshift-merge-bot -o jsonpath='{.data.appid}' | base64 -d
#   oc --context app.ci -n ci get secret openshift-merge-bot -o jsonpath='{.data.cert}' | base64 -d > /tmp/openshift-merge-bot.pem

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON_OUTPUT=false
APP_ID=""
APP_KEY=""
USE_GH_APP=false

for arg in "$@"; do
    case "$arg" in
        --app-id=*) APP_ID="${arg#*=}" ;;
        --app-key=*) APP_KEY="${arg#*=}" ;;
        --json) JSON_OUTPUT=true ;;
        --help|-h)
            echo "Usage: $0 [--app-id=ID --app-key=PATH] [--json]" >&2
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [[ -n "$APP_ID" && -n "$APP_KEY" ]]; then
    USE_GH_APP=true
    if [[ ! -f "$APP_KEY" ]]; then
        echo "ERROR: Private key file not found: $APP_KEY" >&2
        exit 1
    fi
elif [[ -n "$APP_ID" || -n "$APP_KEY" ]]; then
    echo "ERROR: --app-id and --app-key must be specified together" >&2
    exit 1
fi

# --- GitHub App auth helpers ---

generate_jwt() {
    python3 -c "
import jwt, time, sys
now = int(time.time())
payload = {'iat': now - 60, 'exp': now + 540, 'iss': int(sys.argv[1])}
with open(sys.argv[2], 'r') as f:
    key = f.read()
print(jwt.encode(payload, key, algorithm='RS256'))
" "$APP_ID" "$APP_KEY"
}

declare -A ORG_TOKENS
declare -A ORG_TOKEN_FAILURES

get_token_for_org() {
    local org="$1"

    if [[ -n "${ORG_TOKENS[$org]+x}" ]]; then
        echo "${ORG_TOKENS[$org]}"
        return 0
    fi

    if [[ -n "${ORG_TOKEN_FAILURES[$org]+x}" ]]; then
        return 1
    fi

    local jwt
    jwt=$(generate_jwt)

    local install_id
    install_id=$(curl -sf -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/${org}/installation" 2>/dev/null | jq -r '.id') || true

    if [[ -z "$install_id" || "$install_id" == "null" ]]; then
        ORG_TOKEN_FAILURES[$org]=1
        echo "  No app installation for org: ${org}" >&2
        return 1
    fi

    local token
    token=$(curl -sf -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${install_id}/access_tokens" 2>/dev/null | jq -r '.token') || true

    if [[ -z "$token" || "$token" == "null" ]]; then
        ORG_TOKEN_FAILURES[$org]=1
        echo "  Failed to get token for org: ${org}" >&2
        return 1
    fi

    ORG_TOKENS[$org]="$token"
    echo "$token"
}

# --- Repo collection and checking ---

collect_repos() {
    local dirs=("ci-operator/config" "ci-operator/jobs" "core-services/prow/02_config")
    for dir in "${dirs[@]}"; do
        local full_path="${REPO_ROOT}/${dir}"
        [[ -d "$full_path" ]] || continue
        find "$full_path" -mindepth 2 -maxdepth 2 -type d
    done | sed 's|.*/\([^/]*/[^/]*\)$|\1|' | sort -u
}

check_repo_gh() {
    local repo="$1"
    local response

    response=$(gh api "repos/${repo}" --jq '.archived' 2>&1) && {
        if [[ "$response" == "true" ]]; then
            echo "archived"
        else
            echo "active"
        fi
    } || {
        if echo "$response" | grep -q "Not Found"; then
            echo "not_found"
        elif echo "$response" | grep -q "rate limit"; then
            echo "rate_limited"
        else
            echo "error"
        fi
    }
}

check_repo_app() {
    local repo="$1"
    local org="${repo%%/*}"

    local token
    token=$(get_token_for_org "$org") || {
        echo "no_installation"
        return
    }

    local http_code
    http_code=$(curl -s -o /tmp/gh-repo-check.json -w '%{http_code}' \
        -H "Authorization: token $token" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}")

    case "$http_code" in
        200)
            local archived
            archived=$(jq -r '.archived' /tmp/gh-repo-check.json)
            if [[ "$archived" == "true" ]]; then
                echo "archived"
            else
                echo "active"
            fi
            ;;
        404)
            echo "not_found"
            ;;
        403)
            if grep -q "rate limit" /tmp/gh-repo-check.json 2>/dev/null; then
                echo "rate_limited"
            else
                echo "forbidden"
            fi
            ;;
        *)
            echo "error"
            ;;
    esac
}

check_repo() {
    if $USE_GH_APP; then
        check_repo_app "$1"
    else
        check_repo_gh "$1"
    fi
}

present_in() {
    local repo="$1"
    local org repo_name
    org=$(dirname "$repo")
    repo_name=$(basename "$repo")
    local locations=()

    [[ -d "${REPO_ROOT}/ci-operator/config/${org}/${repo_name}" ]] && locations+=("config")
    [[ -d "${REPO_ROOT}/ci-operator/jobs/${org}/${repo_name}" ]] && locations+=("jobs")
    [[ -d "${REPO_ROOT}/core-services/prow/02_config/${org}/${repo_name}" ]] && locations+=("prow")

    echo "${locations[*]}"
}

main() {
    if $USE_GH_APP; then
        echo "Verifying GitHub App credentials..." >&2
        local jwt
        jwt=$(generate_jwt) || { echo "ERROR: Failed to generate JWT. Check app-id and app-key." >&2; exit 1; }

        local app_name
        app_name=$(curl -sf -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app" | jq -r '.name')
        echo "Authenticated as GitHub App: ${app_name}" >&2
    else
        echo "Using gh CLI authentication" >&2
        gh auth status >&2 || { echo "ERROR: gh is not authenticated. Run 'gh auth login' first." >&2; exit 1; }
    fi
    echo >&2

    local repos
    repos=$(collect_repos)
    local total
    total=$(echo "$repos" | wc -l)
    local checked=0
    local archived_repos=()
    local deleted_repos=()
    local no_install_repos=()
    local errors=()

    echo "Found $total unique org/repo pairs to check" >&2
    echo "Checking repository status on GitHub..." >&2
    echo >&2

    while IFS= read -r repo; do
        checked=$((checked + 1))
        if (( checked % 50 == 0 )); then
            echo "  Progress: ${checked}/${total}" >&2
        fi

        local status
        status=$(check_repo "$repo")

        case "$status" in
            archived)
                local locations
                locations=$(present_in "$repo")
                archived_repos+=("${repo}|${locations}")
                echo "  ARCHIVED: ${repo} (in: ${locations})" >&2
                ;;
            not_found)
                local locations
                locations=$(present_in "$repo")
                deleted_repos+=("${repo}|${locations}")
                echo "  NOT FOUND: ${repo} (in: ${locations})" >&2
                ;;
            no_installation)
                no_install_repos+=("$repo")
                ;;
            rate_limited)
                echo "ERROR: GitHub API rate limit reached after checking ${checked}/${total} repos" >&2
                exit 1
                ;;
            error|forbidden)
                errors+=("$repo")
                ;;
        esac
    done <<< "$repos"

    echo >&2
    echo "Done. Checked ${checked} repositories." >&2
    echo "  Archived: ${#archived_repos[@]}" >&2
    echo "  Deleted/Not Found: ${#deleted_repos[@]}" >&2
    if $USE_GH_APP; then
        echo "  No App Installation (skipped): ${#no_install_repos[@]}" >&2
    fi
    echo "  Errors: ${#errors[@]}" >&2
    echo >&2

    if $JSON_OUTPUT; then
        local archived_json not_found_json no_install_json errors_json
        if [[ ${#archived_repos[@]} -gt 0 ]]; then
            archived_json=$(printf '%s\n' "${archived_repos[@]}" | jq -R 'split("|") | {repo: .[0], locations: .[1]}' | jq -s '.')
        else
            archived_json="[]"
        fi
        if [[ ${#deleted_repos[@]} -gt 0 ]]; then
            not_found_json=$(printf '%s\n' "${deleted_repos[@]}" | jq -R 'split("|") | {repo: .[0], locations: .[1]}' | jq -s '.')
        else
            not_found_json="[]"
        fi
        if [[ ${#no_install_repos[@]} -gt 0 ]]; then
            no_install_json=$(printf '%s\n' "${no_install_repos[@]}" | jq -R '.' | jq -s '.')
        else
            no_install_json="[]"
        fi
        if [[ ${#errors[@]} -gt 0 ]]; then
            errors_json=$(printf '%s\n' "${errors[@]}" | jq -R '.' | jq -s '.')
        else
            errors_json="[]"
        fi
        jq -n \
            --argjson archived "$archived_json" \
            --argjson not_found "$not_found_json" \
            --argjson no_installation "$no_install_json" \
            --argjson errors "$errors_json" \
            '{archived: $archived, not_found: $not_found, no_installation: $no_installation, errors: $errors}'
    else
        if [[ ${#archived_repos[@]} -gt 0 ]]; then
            echo "=== Archived Repositories (candidates for offboarding) ==="
            echo ""
            for entry in "${archived_repos[@]}"; do
                echo "  ${entry%%|*}  (in: ${entry#*|})"
            done
            echo ""
        fi

        if [[ ${#deleted_repos[@]} -gt 0 ]]; then
            echo "=== Deleted/Not Found Repositories (candidates for offboarding) ==="
            echo ""
            for entry in "${deleted_repos[@]}"; do
                echo "  ${entry%%|*}  (in: ${entry#*|})"
            done
            echo ""
        fi

        if [[ ${#no_install_repos[@]} -gt 0 ]]; then
            echo "=== Skipped (no app installation in org) ==="
            echo ""
            local skip_orgs
            skip_orgs=$(printf '%s\n' "${no_install_repos[@]}" | sed 's|/.*||' | sort -u)
            echo "  Orgs: ${skip_orgs//$'\n'/, }"
            echo "  Repos skipped: ${#no_install_repos[@]}"
            echo ""
        fi

        if [[ ${#errors[@]} -gt 0 ]]; then
            echo "=== Repositories with errors (could not determine status) ==="
            echo ""
            for entry in "${errors[@]}"; do
                echo "  ${entry}"
            done
            echo ""
        fi
    fi
}

main
