#!/usr/bin/env bash
# Watch one or more branches of a GitHub repo for a commit newer than a cutoff
# timestamp, then report the commit status contexts matching a filter (e.g.
# the postsubmit "images" job that promotes bundle/index images).
#
# Built while chasing the oadp-operator-bundle promotion fix (openshift/release#83282,
# #83049): kdm-controller/kdm-plugin e2e depends on a fresh oadp-operator-bundle
# image that only gets (re)promoted by a real postsubmit run on oadp-dev/oadp-1.6.
# Rehearsing before that postsubmit lands just reproduces the same stale-bundle
# failure -- this script exists so we stop guessing and just watch for it.
#
# Usage:
#   watch_postsubmit_refresh.sh --repo <org/repo> --after <ISO8601-cutoff> \
#     --branch <branch> [--branch <branch> ...] [--context-filter <substr>] \
#     [--interval <seconds>]
#
# Example:
#   watch_postsubmit_refresh.sh --repo openshift/oadp-operator \
#     --after 2026-08-13T18:54:02Z \
#     --branch oadp-dev --branch oadp-1.6 \
#     --context-filter images
#
# Prints one line per newly-observed post-cutoff commit, then its matching
# status contexts. Keeps running (doesn't exit) so it can back a persistent
# Monitor -- stop it externally (TaskStop) once the postsubmit you're
# waiting for has been seen and reported.
set -uo pipefail

REPO=""
CUTOFF=""
CONTEXT_FILTER="images"
INTERVAL=60
BRANCHES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --after) CUTOFF="$2"; shift 2 ;;
    --branch) BRANCHES+=("$2"); shift 2 ;;
    --context-filter) CONTEXT_FILTER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$CUTOFF" ] || [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo "usage: $0 --repo <org/repo> --after <ISO8601-cutoff> --branch <branch> [--branch <branch> ...] [--context-filter <substr>] [--interval <seconds>]" >&2
  exit 1
fi

declare -A last_sha

while true; do
  for branch in "${BRANCHES[@]}"; do
    sha=$(gh api "repos/$REPO/commits/$branch" --jq '.sha' 2>/dev/null || true)
    [ -z "$sha" ] && continue
    if [ "${last_sha[$branch]:-}" != "$sha" ]; then
      last_sha[$branch]="$sha"
      commit_date=$(gh api "repos/$REPO/commits/$sha" --jq '.commit.committer.date' 2>/dev/null || true)
      if [[ "$commit_date" > "$CUTOFF" ]]; then
        echo "NEW $branch commit after cutoff: $sha ($commit_date)"
        status=$(gh api "repos/$REPO/commits/$sha/status" --paginate --jq ".statuses[] | select(.context | contains(\"$CONTEXT_FILTER\")) | \"\(.context): \(.state)\"" 2>/dev/null || true)
        echo "$branch status ($CONTEXT_FILTER): ${status:-<none found>}"
      fi
    fi
  done
  sleep "$INTERVAL"
done
