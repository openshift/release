#!/bin/bash
# Local testing:
#   export GITHUB_TOKEN=$(gh auth token)
#   export PULL_NUMBER=<pr-number>
#   export REPO_OWNER=openshift-hyperfleet
#   export REPO_NAME=hyperfleet-api
#   bash hyperfleet-risk-scorer-commands.sh
set -euo pipefail

echo "=== HyperFleet PR Risk Scorer ==="

# Guard: only run in PR context
if [ -z "${PULL_NUMBER:-}" ]; then
    echo "INFO: PULL_NUMBER not set; skipping (not a PR context)."
    exit 0
fi

# Guard: only run against openshift-hyperfleet repos (avoids 403 on rehearsals)
if [ "${REPO_OWNER:-}" != "openshift-hyperfleet" ]; then
    echo "INFO: Skipping — not an openshift-hyperfleet repo (REPO_OWNER=${REPO_OWNER:-unset})."
    exit 0
fi

# --- GitHub App Authentication ---
# If GITHUB_TOKEN is already set (e.g. local testing via `export GITHUB_TOKEN=$(gh auth token)`),
# skip the GitHub App JWT exchange and use it directly.
if [ -z "${GITHUB_TOKEN:-}" ]; then
    # Tracing is disabled to prevent leaking the private key, JWT, or token.
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${GITHUB_APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "${GITHUB_APP_PRIVATE_KEY_FILE}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"
    GITHUB_TOKEN=$(curl -sf -X POST \
      -H "Authorization: Bearer ${JWT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

    $WAS_TRACING && set -x

    if [ -z "${GITHUB_TOKEN}" ] || [ "${GITHUB_TOKEN}" = "null" ]; then
        echo "ERROR: Failed to obtain GitHub token."
        exit 1
    fi
else
    echo "INFO: Using pre-set GITHUB_TOKEN (local/manual mode)."
fi

API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
AUTH=(-H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json")

# --- Fetch PR diff ---
# Uses the GitHub API instead of git diff because CI clones are shallow
# and PULL_BASE_SHA may not exist locally. Paginates to handle PRs with 100+ files.
PR_FILES="[]"
page=1
while true; do
    PAGE_DATA=$(curl -sf "${AUTH[@]}" "${API}/pulls/${PULL_NUMBER}/files?per_page=100&page=${page}")
    PAGE_LEN=$(echo "${PAGE_DATA}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    PR_FILES=$(printf '%s\n%s' "${PR_FILES}" "${PAGE_DATA}" | python3 -c "import sys,json; chunks=sys.stdin.read().split('\n',1); a=json.loads(chunks[0]); b=json.loads(chunks[1]); print(json.dumps(a+b))")
    [ "${PAGE_LEN}" -lt 100 ] && break
    page=$((page + 1))
done
DIFF_FILES=$(echo "${PR_FILES}" | python3 -c "import sys,json; [print(f['filename']) for f in json.load(sys.stdin)]")
LINES_CHANGED=$(echo "${PR_FILES}" | python3 -c "import sys,json; print(sum(f.get('additions',0)+f.get('deletions',0) for f in json.load(sys.stdin)))")
LINES_CHANGED=${LINES_CHANGED:-0}

# --- Risk Score Calculation ---
# Signals: PR size (+1 or +2), sensitive paths (+2), test coverage (+1 or +2)
# Thresholds: 0-1 = low, 2-3 = medium, 4+ = high
SCORE=0
BREAKDOWN=""

# Signal 1: PR size (>200 lines = +1, >500 lines = +2)
if [ "${LINES_CHANGED}" -gt 500 ]; then
    SCORE=$((SCORE + 2))
    BREAKDOWN="${BREAKDOWN}\n| PR size | ${LINES_CHANGED} lines (>500) | +2 |"
elif [ "${LINES_CHANGED}" -gt 200 ]; then
    SCORE=$((SCORE + 1))
    BREAKDOWN="${BREAKDOWN}\n| PR size | ${LINES_CHANGED} lines (>200) | +1 |"
else
    BREAKDOWN="${BREAKDOWN}\n| PR size | ${LINES_CHANGED} lines | +0 |"
fi

# Signal 2: Sensitive paths (+2 if any match)
# Overridable per-repo via .risk-config.yaml with a sensitive_paths list
DEFAULT_SENSITIVE="cmd/ config/ deploy/ migrations/ auth/"
SENSITIVE_PATHS="${DEFAULT_SENSITIVE}"
if [ -f .risk-config.yaml ]; then
    CUSTOM=$(sed -n '/^sensitive_paths:/,/^[^ ]/{ /^  - /s/^  - //p }' .risk-config.yaml | tr '\n' ' ')
    [ -n "${CUSTOM}" ] && SENSITIVE_PATHS="${CUSTOM}"
fi
SENSITIVE_HIT=""
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    for path in ${SENSITIVE_PATHS}; do
        if [[ "${file}" == "${path}"* ]]; then
            # Avoid duplicates in the hit list
            case " ${SENSITIVE_HIT} " in
                *" ${path} "*) ;;
                *) SENSITIVE_HIT="${SENSITIVE_HIT} ${path}" ;;
            esac
        fi
    done
done <<< "${DIFF_FILES}"
if [ -n "${SENSITIVE_HIT}" ]; then
    SCORE=$((SCORE + 2))
    BREAKDOWN="${BREAKDOWN}\n| Sensitive paths |${SENSITIVE_HIT} | +2 |"
else
    BREAKDOWN="${BREAKDOWN}\n| Sensitive paths | none | +0 |"
fi

# Signal 3: Test coverage (+2 if no tests, +1 if tests miss some packages)
# Checks whether _test.go files exist for the same packages as changed .go files
GO_SRC_PKGS=$(echo "${DIFF_FILES}" | grep '\.go$' | grep -v '_test\.go$' | xargs -I{} dirname {} 2>/dev/null | sort -u || true)
HAS_TESTS=$(echo "${DIFF_FILES}" | grep '_test\.go$' || true)
if [ -n "${GO_SRC_PKGS}" ] && [ -z "${HAS_TESTS}" ]; then
    SCORE=$((SCORE + 2))
    BREAKDOWN="${BREAKDOWN}\n| Test coverage | No _test.go files in diff | +2 |"
elif [ -n "${GO_SRC_PKGS}" ] && [ -n "${HAS_TESTS}" ]; then
    TEST_PKGS=$(echo "${HAS_TESTS}" | xargs -I{} dirname {} 2>/dev/null | sort -u)
    UNCOVERED=""
    for pkg in ${GO_SRC_PKGS}; do
        if ! echo "${TEST_PKGS}" | grep -qx "${pkg}"; then
            UNCOVERED="${UNCOVERED} ${pkg}"
        fi
    done
    if [ -n "${UNCOVERED}" ]; then
        SCORE=$((SCORE + 1))
        BREAKDOWN="${BREAKDOWN}\n| Test coverage | Missing tests for:${UNCOVERED} | +1 |"
    else
        BREAKDOWN="${BREAKDOWN}\n| Test coverage | Tests cover changed packages | +0 |"
    fi
fi

# --- Risk Level ---
if [ "${SCORE}" -ge 4 ]; then
    RISK="high"
elif [ "${SCORE}" -ge 2 ]; then
    RISK="medium"
else
    RISK="low"
fi
echo "Risk score: ${SCORE} -> risk/${RISK}"

# --- Apply Label & Post Comment ---
# API errors should not fail the job since it is informational
set +e

# Create labels if they don't exist yet (422 "already exists" is expected)
for label_info in "risk/low:0e8a16" "risk/medium:fbca04" "risk/high:e11d48"; do
    lname="${label_info%%:*}"
    lcolor="${label_info##*:}"
    curl -s "${AUTH[@]}" -X POST "${API}/labels" \
      -d "{\"name\":\"${lname}\",\"color\":\"${lcolor}\"}" > /dev/null 2>&1
done

# Remove stale risk labels and apply the new one only if something changed
CURRENT_LABELS=$(curl -s "${AUTH[@]}" "${API}/issues/${PULL_NUMBER}/labels" \
  | python3 -c "import sys,json; [print(l['name']) for l in json.load(sys.stdin)]" 2>/dev/null)
if echo "${CURRENT_LABELS}" | grep -qx "risk/${RISK}"; then
    echo "Label risk/${RISK} already set; skipping."
else
    for old in risk/low risk/medium risk/high; do
        if echo "${CURRENT_LABELS}" | grep -qx "${old}"; then
            encoded=$(echo "${old}" | sed 's|/|%2F|g')
            curl -s "${AUTH[@]}" -X DELETE "${API}/issues/${PULL_NUMBER}/labels/${encoded}" > /dev/null 2>&1
        fi
    done
    LABEL_RESULT=$(curl -s -w "\n%{http_code}" "${AUTH[@]}" -X POST "${API}/issues/${PULL_NUMBER}/labels" \
      -d "{\"labels\":[\"risk/${RISK}\"]}")
    LABEL_HTTP=$(echo "${LABEL_RESULT}" | tail -1)
    if [ "${LABEL_HTTP}" -ge 400 ] 2>/dev/null; then
        echo "WARNING: Failed to apply label (HTTP ${LABEL_HTTP}): $(echo "${LABEL_RESULT}" | head -1)"
    fi
fi

# Post or update the score breakdown comment (idempotent via HTML marker)
COMMENT_MARKER="<!-- hyperfleet-risk-scorer -->"
EXISTING_COMMENT_ID=""
cpage=1
while [ -z "${EXISTING_COMMENT_ID}" ]; do
    CPAGE_DATA=$(curl -s "${AUTH[@]}" "${API}/issues/${PULL_NUMBER}/comments?per_page=100&page=${cpage}")
    CPAGE_LEN=$(echo "${CPAGE_DATA}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    EXISTING_COMMENT_ID=$(echo "${CPAGE_DATA}" \
      | python3 -c "import sys,json; comments=[c for c in json.load(sys.stdin) if '${COMMENT_MARKER}' in c.get('body','')]; print(comments[0]['id'] if comments else '')" 2>/dev/null)
    [ "${CPAGE_LEN}" -lt 100 ] && break
    cpage=$((cpage + 1))
done

BODY=$(printf '%s\n## Risk Score: %d — `risk/%s`\n\n| Signal | Detail | Points |\n|--------|--------|--------|\n%b\n\n<sub>Computed by hyperfleet-risk-scorer</sub>' \
  "${COMMENT_MARKER}" "${SCORE}" "${RISK}" "${BREAKDOWN#\\n}")

json_body() { python3 -c "import sys,json; print(json.dumps({'body': sys.stdin.read()}))" <<< "${BODY}"; }

if [ -n "${EXISTING_COMMENT_ID}" ]; then
    COMMENT_RESULT=$(curl -s -w "\n%{http_code}" "${AUTH[@]}" -X PATCH "${API}/issues/comments/${EXISTING_COMMENT_ID}" \
      -d "$(json_body)")
    echo "Updated existing comment ${EXISTING_COMMENT_ID}"
else
    COMMENT_RESULT=$(curl -s -w "\n%{http_code}" "${AUTH[@]}" -X POST "${API}/issues/${PULL_NUMBER}/comments" \
      -d "$(json_body)")
    echo "Posted new comment"
fi
COMMENT_HTTP=$(echo "${COMMENT_RESULT}" | tail -1)
if [ "${COMMENT_HTTP}" -ge 400 ] 2>/dev/null; then
    echo "WARNING: Failed to post comment (HTTP ${COMMENT_HTTP}): $(echo "${COMMENT_RESULT}" | head -1)"
fi

set -e

echo "=== Risk scoring complete ==="
