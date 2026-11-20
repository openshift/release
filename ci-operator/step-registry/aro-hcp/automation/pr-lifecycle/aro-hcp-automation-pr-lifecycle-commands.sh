#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================================
# SECURITY WARNING
# ============================================================================
# This script handles GitHub App credentials (App ID + private key).
# NEVER enable 'set -x' or 'set -o xtrace': it would expose the credentials
# in the job logs. Use VERBOSITY=1 for controlled logging instead.
# ============================================================================

set +o xtrace
trap 'set +o xtrace' DEBUG

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${*}"; }
error() { log "[error] ${*}"; exit "${ERR_EXIT_CODE:-1}"; }

VERBOSITY=${VERBOSITY:-0}
MODE=${LIFECYCLE_MODE:-}
DRY_RUN=${LIFECYCLE_DRY_RUN:-false}
CEILING=${LIFECYCLE_CEILING:-30}
ORG=${GITHUB_REPO_ORG:-Azure}
REPO=${GITHUB_REPO_NAME:-ARO-HCP}

[[ -n "${MODE}" ]] || error "LIFECYCLE_MODE is required"
[[ -r "${GITHUB_APP_ID_PATH}" ]] || error "cannot read ${GITHUB_APP_ID_PATH}"
[[ -r "${GITHUB_APP_KEY_PATH}" ]] || error "cannot read ${GITHUB_APP_KEY_PATH}"

# Exclusions shared by every mode. Frozen and held pull requests are never
# touched, and merge blockers are left to the owning team.
EXCLUSIONS="-label:lifecycle/frozen -label:tide/merge-blocker -label:do-not-merge/hold"

case "${MODE}" in
stale)
  updated=720h
  filter="-label:lifecycle/stale -label:lifecycle/rotten"
  empty_message="Nothing to mark stale: no open pull request has been inactive for 30 days."
  action_label="lifecycle/stale"
  status_change="open → stale"
  comment=$(cat <<'EOF'
This pull request has had no activity for 30 days and is being marked stale.

Comment `/remove-lifecycle stale` to keep it open, or `/close` if it can be closed.

/lifecycle stale
EOF
)
  ;;
rotten)
  updated=336h
  filter="label:lifecycle/stale -label:lifecycle/rotten"
  empty_message="Nothing to mark rotten: no stale pull request has been inactive for 14 more days."
  action_label="lifecycle/rotten"
  status_change="stale → rotten"
  comment=$(cat <<'EOF'
This stale pull request has had no activity for 14 additional days and is being marked rotten.

Comment `/remove-lifecycle rotten` to keep it open, or `/close` if it can be closed.
Rotten pull requests are closed after 7 more days without activity.

/lifecycle rotten
/remove-lifecycle stale
EOF
)
  ;;
close)
  updated=168h
  filter="label:lifecycle/rotten"
  empty_message="Nothing to close: no rotten pull request has been inactive for 7 more days."
  action_label=""
  status_change="rotten → closed"
  comment=$(cat <<'EOF'
This rotten pull request has had no activity for 7 additional days and is being closed.

Reopen it if it is still relevant.

/close
EOF
)
  ;;
*)
  error "unknown LIFECYCLE_MODE: ${MODE}"
  ;;
esac

query="repo:${ORG}/${REPO} is:pr is:open comments:<2500 ${filter} ${EXCLUSIONS}"

args=(
  "--query=${query}"
  "--updated=${updated}"
  "--ceiling=${CEILING}"
  "--github-org=${ORG}"
  "--github-app-id=$(cat "${GITHUB_APP_ID_PATH}")"
  "--github-app-private-key-path=${GITHUB_APP_KEY_PATH}"
  "--comment=${comment}"
)

case "${DRY_RUN}" in
true)
  log "dry run: matching pull requests are logged but not commented on"
  ;;
false)
  args+=("--confirm")
  ;;
*)
  error "LIFECYCLE_DRY_RUN must be 'true' or 'false', got '${DRY_RUN}'"
  ;;
esac

if [[ "${VERBOSITY}" -ge 1 ]]; then
  log "mode=${MODE} org=${ORG} repo=${REPO} updated=${updated} ceiling=${CEILING} dry_run=${DRY_RUN}"
  log "query=${query}"
fi

readonly ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

if [[ "${DRY_RUN}" == "true" ]]; then
  readonly status_suffix=" (dry run)"
else
  readonly status_suffix=""
fi

# xml_escape escapes a string for use in XML text and attribute values.
xml_escape() {
  printf '%s' "${1}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

raw_log=$(mktemp)
set +o errexit
/usr/bin/commenter "${args[@]}" 2>&1 | tee "${raw_log}"
commenter_status=${PIPESTATUS[0]}
set -o errexit

# The commenter reports one "Matched <url> (<title>)" line per pull request it
# acts on. Anchoring on the log prefix keeps a title that contains a "Matched"
# sequence from being read as another line, and the URL pattern restricts the
# value to this repository, so nothing else can reach the reports.
log_prefix='^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]+ main\.go:[0-9]+: '
url_pattern="https://github\\.com/${ORG}/${REPO}/pull/[0-9]+"
total=$(sed -nE "s#${log_prefix}Found ([0-9]+) matches\$#\1#p" "${raw_log}" | tail -1)
total=${total:-0}
matched=$(sed -nE "s#${log_prefix}Matched (${url_pattern}) \((.*)\)\$#\1\t\2#p" "${raw_log}")
processed=$(printf '%s' "${matched}" | grep -c . || true)

# The commenter appends its own qualifiers to the query it runs, so the report
# both shows and links the effective query instead of the raw one.
query_cutoff=$(date -u -d "@$(( $(date +%s) - ${updated%h} * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)
effective_query="${query} archived:false is:open is:unlocked updated:<=${query_cutoff}"
query_url="https://github.com/search?q=${effective_query// /%20}&type=pullrequests"
query_url=${query_url//</%3C}
query_url=${query_url//>/%3E}

junit="${ARTIFACT_DIR}/junit_pr-lifecycle_${MODE}.xml"
# The "-summary.html" suffix matches the spyglass html lens, so the report is
# rendered inline on the job page.
html="${ARTIFACT_DIR}/pr-lifecycle-summary.html"
if [[ "${DRY_RUN}" == "true" ]]; then
  badge='<span class="badge dry">dry run</span>'
else
  badge='<span class="badge live">live</span>'
fi

{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<testsuite name="pr-lifecycle-%s" tests="%s" failures="0" errors="0" skipped="0">\n' "${MODE}" "${processed}"
  while IFS=$'\t' read -r url title; do
    [[ -n "${url}" ]] || continue
    printf '  <testcase classname="pr-lifecycle/%s" name="%s">\n' "${MODE}" "$(xml_escape "${title}")"
    printf '    <system-out>%s%s: %s</system-out>\n' "${status_change}" "${status_suffix}" "$(xml_escape "${url}")"
    printf '  </testcase>\n'
  done <<< "${matched}"
  printf '</testsuite>\n'
} > "${junit}"

{
  printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="color-scheme" content="light dark">\n<title>PR lifecycle: %s</title>\n<style>\n' "$(xml_escape "${MODE}")"
  cat <<'HTML'
html, body { margin: 0; padding: 0; background: transparent; }
.report { padding: 10px 12px 12px; }
body { padding: 0; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; color: #1f2328; }
.meta { margin: 0 0 10px; color: #59636e; }
.empty { margin: 0; padding: 14px; border: 1px dashed #d1d9e0; border-radius: 6px; color: #59636e; font-size: 14px; }
.query { margin: 10px 0 0; color: #59636e; font-size: 12px; }
.query .qlabel { display: inline-block; margin-right: 6px; font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; }
.query a { color: inherit; text-decoration: none; }
.query a:hover code { text-decoration: underline; }
.query .arrow { margin-left: 4px; }
.query code { font: 12px/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; white-space: pre-wrap; word-break: break-word; }
.table-wrap { max-height: 520px; overflow: auto; border: 1px solid #d1d9e0; border-radius: 6px; }
table { border-collapse: separate; border-spacing: 0; width: 100%; }
th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #d1d9e0; vertical-align: top; }
thead th { position: sticky; top: 0; z-index: 1; background: #f6f8fa; font-weight: 600; }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover td { background: #f6f8fa; }
td.num { white-space: nowrap; font-variant-numeric: tabular-nums; }
td.lbl { white-space: nowrap; }
td.lbl code { padding: 1px 8px; border-radius: 10px; background: #eff2f5; font-size: 12px; }
a { color: #0969da; text-decoration: none; }
a:hover { text-decoration: underline; }
.badge { display: inline-block; padding: 1px 9px; border-radius: 10px; font-size: 12px; font-weight: 600; }
.badge.dry { background: #fff8c5; color: #7d4e00; }
.badge.live { background: #dafbe1; color: #116329; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; }
  .meta { color: #9198a1; }
  .table-wrap { border-color: #30363d; }
  .empty { border-color: #30363d; color: #9198a1; }
  .query { color: #9198a1; }
  th, td { border-color: #30363d; }
  thead th { background: #161b22; }
  tbody tr:hover td { background: #161b22; }
  td.lbl code { background: #21262d; }
  a { color: #4493f8; }
  .badge.dry { background: #3a2d00; color: #e3b341; }
  .badge.live { background: #0f2f1a; color: #3fb950; }
}
</style>
</head>
<body>
<div class="report">
HTML
  printf '<p class="meta">Matched %s pull requests, processed %s of a %s per-run ceiling. %s Oldest activity first.</p>\n' \
    "${total}" "${processed}" "${CEILING}" "${badge}"
  if [[ "${processed}" -eq 0 ]]; then
    printf '<p class="empty">%s</p>\n' "$(xml_escape "${empty_message}")"
  else
    printf '<div class="table-wrap">\n<table>\n<thead><tr><th>Pull request</th><th>Title</th><th>Label</th><th>Status</th></tr></thead>\n<tbody>\n'
    while IFS=$'\t' read -r url title; do
      [[ -n "${url}" ]] || continue
      number=${url##*/}
      if [[ -n "${action_label}" ]]; then
        label_cell="<code>$(xml_escape "${action_label}")</code>"
      else
        label_cell="-"
      fi
      printf '<tr><td class="num"><a href="%s">#%s</a></td><td>%s</td><td class="lbl">%s</td><td>%s</td></tr>\n' \
        "$(xml_escape "${url}")" "$(xml_escape "${number}")" "$(xml_escape "${title}")" "${label_cell}" "${status_change}"
    done <<< "${matched}"
    printf '</tbody>\n</table>\n</div>\n'
  fi
  printf '<p class="query"><span class="qlabel">Query</span><a href="%s" target="_blank" rel="noopener"><code>%s</code><span class="arrow">↗</span></a></p>\n' \
    "$(xml_escape "${query_url}")" "$(xml_escape "${effective_query}")"
  printf '</div>\n</body>\n</html>\n'
} > "${html}"

log "processed ${processed} of ${total} matches, reports written to ${junit} and ${html}"

if [[ "${commenter_status}" -ne 0 ]]; then
  log "[error] commenter exited with ${commenter_status}; the reports list the pull requests seen before the failure"
  exit "${commenter_status}"
fi
