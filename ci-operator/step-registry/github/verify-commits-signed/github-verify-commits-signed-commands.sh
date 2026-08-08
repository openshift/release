#!/bin/bash

set -euo pipefail

if [[ -z "${PULL_NUMBER:-}" ]]; then
  echo "[WARN] PULL_NUMBER is not set — skipping commit signature verification."
  exit 0
fi

echo "Checking signature status for PR #${PULL_NUMBER} in ${REPO_OWNER}/${REPO_NAME}..."

all_commits="[]"
page=1
while true; do
  page_json=$(curl -sS -f \
    --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-delay 2 --retry-connrefused \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PULL_NUMBER}/commits?per_page=100&page=${page}")
  count=$(jq length <<< "${page_json}")
  if [[ "${count}" -eq 0 ]]; then
    break
  fi
  all_commits=$(jq -c -n --argjson a "$all_commits" --argjson b "$page_json" '$a + $b')
  if [[ "${count}" -lt 100 ]]; then
    break
  fi
  page=$((page + 1))
done

total=$(jq length <<< "${all_commits}")
unsigned=0

while IFS=$'\t' read -r sha verified reason; do
  short_sha="${sha:0:12}"
  if [[ "${verified}" == "true" ]]; then
    echo "  [SIGNED]   ${short_sha}"
  else
    echo "  [UNSIGNED] ${short_sha} — reason: ${reason}"
    unsigned=$((unsigned + 1))
  fi
done < <(jq -r '.[] | [.sha, (.commit.verification.verified | tostring), .commit.verification.reason] | @tsv' <<< "${all_commits}")

echo ""
echo "Total commits: ${total}, Unsigned: ${unsigned}"

if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  jq --argjson total "${total}" --argjson unsigned "${unsigned}" \
    '{total: $total, unsigned: $unsigned, commits: [.[] | {sha: .sha, verified: .commit.verification.verified, reason: .commit.verification.reason}]}' \
    <<< "${all_commits}" > "${ARTIFACT_DIR}/commit_report.json"
fi

if [[ "${unsigned}" -gt 0 ]]; then
  echo "ERROR: ${unsigned} commit(s) are not signed. All commits must be signed."
  exit 1
fi

echo "All ${total} commit(s) are signed."
