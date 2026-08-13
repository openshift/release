#!/usr/bin/env bash
# Watch a commit's GitHub status contexts (e.g. Prow rehearsal or presubmit
# jobs) until every matching context leaves the "pending" state, printing
# each state transition as it happens.
#
# Built during openshift/release#83049 (KDM e2e migration) to watch
# /pj-rehearse-triggered contexts on a PR's HEAD commit without polling by
# hand or guessing when a rehearsal run is actually done.
#
# Usage:
#   watch_pr_status.sh --repo <org/repo> --sha <sha> [--context-filter <substr>] \
#     [--interval <seconds>]
#
# Example:
#   watch_pr_status.sh --repo openshift/release --sha 19b8798... \
#     --context-filter rehearse
#
# Prints a line per state change per context. Exits (prints
# "ALL <filter> CONTEXTS FINISHED") once at least one matching context has
# been seen and none remain pending -- safe to back a persistent Monitor,
# since the monitor's underlying command exiting ends the watch.
set -uo pipefail

REPO=""
SHA=""
CONTEXT_FILTER="rehearse"
INTERVAL=60

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --context-filter) CONTEXT_FILTER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$SHA" ]; then
  echo "usage: $0 --repo <org/repo> --sha <sha> [--context-filter <substr>] [--interval <seconds>]" >&2
  exit 1
fi

declare -A last_state

while true; do
  statuses=$(gh api "repos/$REPO/commits/$SHA/status" --paginate --jq ".statuses[] | select(.context | contains(\"$CONTEXT_FILTER\")) | \"\(.context)|\(.state)|\(.target_url)\"" 2>/dev/null || true)

  if [ -z "$statuses" ]; then
    echo "no $CONTEXT_FILTER statuses yet on $SHA"
  else
    while IFS='|' read -r ctx state url; do
      [ -z "$ctx" ] && continue
      if [ "${last_state[$ctx]:-}" != "$state" ]; then
        last_state[$ctx]="$state"
        echo "$ctx: $state ($url)"
      fi
    done <<< "$statuses"
  fi

  all_done=true
  any=false
  for ctx in "${!last_state[@]}"; do
    any=true
    [ "${last_state[$ctx]}" == "pending" ] && all_done=false
  done

  if $any && $all_done; then
    echo "ALL $CONTEXT_FILTER CONTEXTS FINISHED (final states above)"
    break
  fi

  sleep "$INTERVAL"
done
