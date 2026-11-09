#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
export CLAUDE_CONFIG_DIR

# --- Gangway overrides ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_VIEW:-}" ]]; then
    echo "Applying Gangway override: TRIAGE_VIEW=${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_VIEW}"
    TRIAGE_VIEW="${MULTISTAGE_PARAM_OVERRIDE_TRIAGE_VIEW}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REPO:-}" ]]; then
    echo "Applying Gangway override: AI_HELPERS_REPO=${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REPO}"
    AI_HELPERS_REPO="${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REPO}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REF:-}" ]]; then
    echo "Applying Gangway override: AI_HELPERS_REF=${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REF}"
    AI_HELPERS_REF="${MULTISTAGE_PARAM_OVERRIDE_AI_HELPERS_REF}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL:-}" ]]; then
    echo "Applying Gangway override: CLAUDE_MODEL=${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL}"
    CLAUDE_MODEL="${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL}"
fi
for var in TRIAGE_VIEWS TRIAGE_WRITES TRIAGE_ACK_RECEIPT; do
    override_var="MULTISTAGE_PARAM_OVERRIDE_${var}"
    if [[ -n "${!override_var:-}" ]]; then
        echo "Applying Gangway override: ${var}=${!override_var}"
        printf -v "${var}" '%s' "${!override_var}"
    fi
done

# --- Policy knobs (defaults keep the historical devel behaviour) ---
# TRIAGE_POLICY: devel (release in development) or ga (released versions); pre-ga/post-ga are accepted aliases.
TRIAGE_POLICY="${TRIAGE_POLICY:-devel}"
case "${TRIAGE_POLICY}" in
    devel|pre-ga|duty) TRIAGE_POLICY="devel" ;;
    ga|post-ga) TRIAGE_POLICY="ga" ;;
    *) echo "ERROR: TRIAGE_POLICY must be devel or ga (got '${TRIAGE_POLICY}')."; exit 1 ;;
esac
TRIAGE_ANALYSIS="${TRIAGE_ANALYSIS:-full}"
case "${TRIAGE_ANALYSIS}" in
    full|quick) ;;
    *) echo "ERROR: TRIAGE_ANALYSIS must be full or quick (got '${TRIAGE_ANALYSIS}')."; exit 1 ;;
esac
# TRIAGE_WRITES: none (report only) | existing (only for matches to existing bugs) | all (may also file new bugs).
if [[ -z "${TRIAGE_WRITES:-}" ]]; then
    if [[ "${TRIAGE_POLICY}" == "ga" ]]; then TRIAGE_WRITES="none"; else TRIAGE_WRITES="all"; fi
fi
case "${TRIAGE_POLICY}/${TRIAGE_WRITES}" in
    ga/none|ga/existing|devel/existing|devel/all) ;;
    ga/all) echo "ERROR: TRIAGE_WRITES=all is not allowed with TRIAGE_POLICY=ga (the GA policy never files new bugs)."; exit 1 ;;
    devel/none) echo "ERROR: TRIAGE_WRITES=none is only supported with TRIAGE_POLICY=ga."; exit 1 ;;
    *) echo "ERROR: TRIAGE_WRITES must be none, existing or all (got '${TRIAGE_WRITES}')."; exit 1 ;;
esac
# Internal flags the skill and the audit scripts understand.
TRIAGE_EXISTING_ONLY="false"
if [[ "${TRIAGE_WRITES}" != "all" ]]; then TRIAGE_EXISTING_ONLY="true"; fi
WRITE_MODE_REQUESTED="auto"
if [[ "${TRIAGE_WRITES}" == "none" ]]; then WRITE_MODE_REQUESTED="report"; fi
TRIAGE_BASELINE="${TRIAGE_BASELINE:-auto}"
TRIAGE_VIEWS="${TRIAGE_VIEWS:-}"
TRIAGE_ACK_RECEIPT="${TRIAGE_ACK_RECEIPT:-}"
# Where the ai-helpers bulk-triage scripts live (overridable for rehearsal from a checkout).
AIH_SCRIPTS_DIR="${AIH_SCRIPTS_DIR:-/opt/ai-helpers/plugins/ci/skills/bulk-triage-regressions/scripts}"
# Optional local inventory for the pre-pass (testing/rehearsal only; skips Sippy and the oracle).
TRIAGE_INVENTORY_FILE="${TRIAGE_INVENTORY_FILE:-}"
GCS_BUCKET="${GCS_BUCKET:-test-platform-results}"
RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Load JIRA credentials (read + write) ---
# Mounted from the openshift-qse-jira-sa test-credentials secret: an
# OAuth 2.0 client credential of the service account. The ai-helpers scripts
# exchange JIRA_CLIENT_ID/JIRA_CLIENT_SECRET for short-lived access tokens
# themselves and call https://api.atlassian.com/ex/jira/${JIRA_CLOUD_ID}, both
# to look up existing bugs and to write as the service account (append triage
# links, comment, file new bugs).
# Disable tracing so the secret is never echoed into the CI logs.
set +x
if [[ -f "${JIRA_CLIENT_ID_PATH:-}" && -f "${JIRA_CLIENT_SECRET_PATH:-}" ]]; then
    export JIRA_CLIENT_ID JIRA_CLIENT_SECRET JIRA_CLOUD_ID JIRA_URL
    JIRA_CLIENT_ID="$(cat "${JIRA_CLIENT_ID_PATH}")"
    JIRA_CLIENT_SECRET="$(cat "${JIRA_CLIENT_SECRET_PATH}")"
    JIRA_URL="${JIRA_URL:-https://redhat.atlassian.net}"
    if [[ -z "${JIRA_CLIENT_ID}" || -z "${JIRA_CLIENT_SECRET}" ]]; then
        echo "ERROR: JIRA service-account credentials are empty (JIRA_CLIENT_ID_PATH/JIRA_CLIENT_SECRET_PATH)."
        exit 1
    fi
    echo "JIRA service-account credentials loaded (read + write)."
else
    echo "Warning: JIRA credentials not found (JIRA_CLIENT_ID_PATH/JIRA_CLIENT_SECRET_PATH); JIRA lookups will be skipped."
fi

# --- Load DPCR (Sippy) bearer token for triage-record writes ---
# Mounted from the claude-bulk-triage-dpcr-token test-credentials secret (a
# service-account token from the TRT-owned sippy namespace on DPCR). Used to
# authenticate to sippy-auth.dptools.openshift.org for creating/updating triage
# records and the reevaluate symptom probe. Still under 'set +x' so it is never
# echoed into the CI logs.
if [[ -f "${DPCR_TOKEN_PATH:-}" ]]; then
    export DPCR_TOKEN
    DPCR_TOKEN="$(cat "${DPCR_TOKEN_PATH}")"
    echo "DPCR bearer token loaded (Sippy triage writes enabled)."
else
    echo "Warning: DPCR token not found (DPCR_TOKEN_PATH); Sippy triage writes and the reevaluate probe will be unavailable."
fi
if [[ "${TRIAGE_POLICY}" == "ga" ]]; then
    # The agent gets the loaded values only, never the mount paths.
    unset JIRA_EMAIL_PATH JIRA_PAT_PATH DPCR_TOKEN_PATH
fi

# --- Optional: replace the baked-in ai-helpers with a custom repo/branch ---
# The image's Claude plugin marketplace points at the /opt/ai-helpers
# directory (group-writable), so replacing its contents is sufficient.
if [[ -n "${AI_HELPERS_REPO:-}" ]]; then
    echo "Using custom ai-helpers: ${AI_HELPERS_REPO}@${AI_HELPERS_REF}"
    CUSTOM_DIR=$(mktemp -d /tmp/ai-helpers-custom-XXXXXX)
    git clone --depth 1 --branch "${AI_HELPERS_REF}" \
        "https://github.com/${AI_HELPERS_REPO}.git" "${CUSTOM_DIR}" \
        || { echo "ERROR: Failed to clone ${AI_HELPERS_REPO}@${AI_HELPERS_REF}"; exit 1; }
    if [[ ! -f "${CUSTOM_DIR}/.claude-plugin/marketplace.json" ]]; then
        echo "ERROR: ${AI_HELPERS_REPO}@${AI_HELPERS_REF} does not look like an ai-helpers checkout (missing .claude-plugin/marketplace.json)."
        exit 1
    fi
    find /opt/ai-helpers -mindepth 1 -delete
    # No -a/--preserve: /opt/ai-helpers itself is owned by another UID (we
    # only have group-write), so preserving ownership/times on it fails.
    cp -r --no-preserve=mode,ownership,timestamps "${CUSTOM_DIR}/." /opt/ai-helpers/
    rm -rf "${CUSTOM_DIR}"
    echo "Replaced /opt/ai-helpers with ${AI_HELPERS_REPO}@${AI_HELPERS_REF} ($(git -C /opt/ai-helpers rev-parse --short HEAD 2>/dev/null || echo 'unknown rev'))"
fi

if [[ -n "${TRIAGE_VIEWS}" ]]; then
    # Multi-view run (GA): the first view keeps legacy single-view variables meaningful.
    TRIAGE_VIEW="${TRIAGE_VIEWS%% *}"
fi
if [[ -z "${TRIAGE_VIEW:-}" ]]; then
    echo "TRIAGE_VIEW not set, detecting latest OCP version from Sippy..."
    LATEST_VERSION=$(curl -sf "https://sippy.dptools.openshift.org/api/releases" | jq -r '.releases[] | select(test("^[0-9]+\\.[0-9]+$"))' | head -1)
    if [[ -z "${LATEST_VERSION}" ]]; then
        echo "ERROR: Could not determine latest OCP version from Sippy."
        exit 1
    fi
    TRIAGE_VIEW="${LATEST_VERSION}-main"
    echo "Auto-selected view: ${TRIAGE_VIEW}"
fi
TRIAGE_VIEWS="${TRIAGE_VIEWS:-${TRIAGE_VIEW}}"

# Skill flag and rulebook for the GA policy. ai-helpers renamed post-ga to ga (keeping post-ga as an alias);
# use whichever the installed copy has so the step works before and after the image picks up the rename.
GA_POLICY_FLAG="ga"
GA_POLICY_DOC="references/ga-policy.md"
if [[ ! -f "${AIH_SCRIPTS_DIR}/../${GA_POLICY_DOC}" && -f "${AIH_SCRIPTS_DIR}/../references/post-ga-policy.md" ]]; then
    GA_POLICY_FLAG="post-ga"
    GA_POLICY_DOC="references/post-ga-policy.md"
fi

# Resolve component scope. An empty value or the sentinel "all"
# (case-insensitive) means triage every component in the view: run
# list_regressions.py without a --components filter, rather than following
# the skill default of asking which components the duty covers.
TRIAGE_COMPONENTS="${TRIAGE_COMPONENTS:-}"
if [[ -z "${TRIAGE_COMPONENTS}" || "${TRIAGE_COMPONENTS,,}" == "all" ]]; then
    TRIAGE_COMPONENTS_DISPLAY="all"
    COMPONENTS_CLAUSE="ALL components in the view. Do NOT ask which components the duty covers and do NOT pass a --components filter: run list_regressions.py with only --view so every component is inventoried"
else
    TRIAGE_COMPONENTS_DISPLAY="${TRIAGE_COMPONENTS}"
    COMPONENTS_CLAUSE="components: ${TRIAGE_COMPONENTS}"
fi

# In existing-only mode the skill never files new JIRA issues. The prompts
# below authorize bug filing, so the mode is restated after them as an
# explicit override rather than left to the flag alone.
EXISTING_ONLY_CLAUSE=""
EXISTING_ONLY_OVERRIDE=""
if [[ "${TRIAGE_EXISTING_ONLY,,}" == "true" ]]; then
    EXISTING_ONLY_CLAUSE=", run in --existing-only mode"
    EXISTING_ONLY_OVERRIDE="

**EXISTING-ONLY MODE**: this run uses the skill's --existing-only mode, which overrides every authorization above to file new JIRA issues. Do NOT create any new JIRA issue. The only writes allowed are the ones the skill's 'Existing-only mode' section permits for a verified match to an existing issue: extending a triage or creating one for that existing issue, ci:add-jira-triage-link, and a comment on that issue using the skill's jira-comment.md template. Every bucket that would need a new bug goes into the report under 'Proposed new bugs (not filed)' and its regressions stay untriaged."
fi

echo "Starting claude bulk-triage-regressions run"
if [[ "${TRIAGE_POLICY}" == "ga" ]]; then
    echo "Views: ${TRIAGE_VIEWS}"
    echo "Policy: ga (skill --policy ${GA_POLICY_FLAG}; analysis ${TRIAGE_ANALYSIS}, writes ${TRIAGE_WRITES}, baseline ${TRIAGE_BASELINE})"
else
    echo "View: ${TRIAGE_VIEW}"
fi
echo "Components: ${TRIAGE_COMPONENTS_DISPLAY}"
echo "Existing-only: ${TRIAGE_EXISTING_ONLY}"
echo "Model: ${CLAUDE_MODEL}"

# Existing-only mode: pass --existing-only to the skill and narrow the JIRA
# write scope to matches against existing issues (no new bugs).
EXISTING_ONLY_FLAG=""
JIRA_WRITE_SCOPE="and ARE authorized to file new bugs (/jira:create bug against the OWNING component, label component-regression), comment on existing issues, and run ci:add-jira-triage-link after each triage."
JIRA_BUG_SCOPE="to file new JIRA bugs against the owning component for buckets with no existing bug, "
EXISTING_ONLY_REPORT=""
if [[ "${TRIAGE_EXISTING_ONLY:-false}" == "true" ]]; then
    EXISTING_ONLY_FLAG=" with --existing-only"
    JIRA_WRITE_SCOPE="and ARE authorized, only for a verified match to an existing issue, to comment on that issue and run ci:add-jira-triage-link after each triage. You are NOT authorized to create, reopen, or transition JIRA issues: every bucket that needs a new bug goes in the report as a draft under 'Proposed new bugs (not filed)'."
    JIRA_BUG_SCOPE=""
    EXISTING_ONLY_REPORT=" Because --existing-only is set, do NOT file any JIRA issue; the report must also contain the 'Proposed new bugs (not filed)' section (even if empty)."
fi
echo "Writes: ${TRIAGE_WRITES} (existing-only ${TRIAGE_EXISTING_ONLY})"

# Install gcloud CLI for GCS artifact access (no root required)
echo "Installing gcloud CLI..."
curl -sSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C /tmp
/tmp/google-cloud-sdk/install.sh --quiet --path-update true
export PATH="/tmp/google-cloud-sdk/bin:${PATH}"
echo "gcloud CLI installed."

WORKDIR=$(mktemp -d /tmp/claude-bulk-triage-XXXXXX)
cd "${WORKDIR}"

REPORT_FILE="triage-duty-report-${TRIAGE_VIEW}.md"
if [[ "${TRIAGE_POLICY}" == "ga" ]]; then
    REPORT_FILE="ga-triage-duty-report.md"
fi
# HTML copy of the report for the Prow job page (the spyglass html lens shows artifacts named *-summary*.html).
SUMMARY_HTML="ga-triage-summary.html"
if [[ "${TRIAGE_ANALYSIS}" == "quick" ]]; then
    SUMMARY_HTML="ga-burst-summary.html"
elif [[ "${TRIAGE_POLICY}" != "ga" ]]; then
    SUMMARY_HTML="triage-summary-${TRIAGE_VIEW}.html"
fi
# Test-name prefix: failures of this job are routed to the Test Framework component.
PHASE_PREFIX='[Jira:"Test Framework"]'

render_summary_html() {
    # Deterministic markdown -> HTML (stdlib only, no LLM). Quick runs summarise burst-status.json instead.
    local src="${WORKDIR:-}/${REPORT_FILE}" title="${REPORT_FILE}"
    if [[ "${TRIAGE_ANALYSIS}" == "quick" ]]; then
        [[ -s "${ARTIFACT_DIR}/burst-status.json" ]] || return 0
        src="${WORKDIR}/burst-summary.md"
        title="Component Readiness burst tripwire"
        jq -r '"# Component Readiness burst tripwire\n\nObserved \(.observation.time) over the last \(.observation.window_hours) hours.\n\n## Triggers (\(.triggers | length))\n\n"
            + (if (.triggers | length) == 0 then "No trigger fired.\n" else
                ([.triggers[] | "- **\(.level) \(.kind)** `\(.cluster_id)`: \((.reasons // []) | join("; "))"] | join("\n")) + "\n" end)
            + "\n## Views\n\n| View | Fetch | Open | Open untriaged | Opened 7d | Closed 7d |\n|---|---|---|---|---|---|\n"
            + ([.observation.views[] | "| \(.view) | \(.fetch) | \(.open // "—") | \(.open_untriaged // "—") | \(.opened_7d // "—") | \(.closed_7d // "—") |"] | join("\n")) + "\n"' \
            "${ARTIFACT_DIR}/burst-status.json" > "${src}" 2>/dev/null || return 0
    fi
    [[ -s "${src}" ]] || return 0
    python3 - "${src}" "${ARTIFACT_DIR}/${SUMMARY_HTML}" "${title}" <<'PYEOF' || echo "Warning: could not render ${SUMMARY_HTML}."
import html, re, sys

src, out, title = sys.argv[1:4]
lines = open(src, encoding="utf-8", errors="replace").read().splitlines()


def inline(t):
    codes = []

    def keep(m):
        codes.append("<code>%s</code>" % html.escape(m.group(1)))
        return "\x00%d\x00" % (len(codes) - 1)

    t = re.sub(r"`([^`]+)`", keep, t)
    t = html.escape(t, quote=False)
    links = []

    def link(href, text):
        links.append('<a href="%s">%s</a>' % (href.replace('"', "%22"), text))
        return "\x01%d\x01" % (len(links) - 1)

    t = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", lambda m: link(m.group(2), m.group(1)), t)
    t = re.sub(r"https?://[^\s<)\]]+", lambda m: link(m.group(0), m.group(0)), t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"<em>\1</em>", t)
    t = re.sub(r"\x01(\d+)\x01", lambda m: links[int(m.group(1))], t)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], t)


def cells(row):
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|"):
        row = row[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", row)]


body, para, i = [], [], 0


def flush():
    if para:
        body.append("<p>%s</p>" % inline(" ".join(para)))
        para.clear()


while i < len(lines):
    s = lines[i].strip()
    if s.startswith("```"):
        flush()
        i += 1
        code = []
        while i < len(lines) and not lines[i].strip().startswith("```"):
            code.append(lines[i])
            i += 1
        body.append("<pre><code>%s</code></pre>" % html.escape("\n".join(code)))
    elif not s:
        flush()
    elif re.match(r"^#{1,6}\s", s):
        flush()
        n = len(s) - len(s.lstrip("#"))
        body.append("<h%d>%s</h%d>" % (n, inline(s[n:].strip()), n))
    elif re.match(r"^(-{3,}|\*{3,}|_{3,})$", s):
        flush()
        body.append("<hr>")
    elif s.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*:?-{2,}", lines[i + 1].strip()):
        flush()
        head = cells(s)
        i += 2
        rows = []
        while i < len(lines) and lines[i].strip().startswith("|"):
            rows.append(cells(lines[i]))
            i += 1
        body.append("<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>" % (
            "".join("<th>%s</th>" % inline(c) for c in head),
            "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % inline(c) for c in r) for r in rows)))
        continue
    elif re.match(r"^([-*+]|\d+[.)])\s", s):
        flush()
        tag = "ol" if s[0].isdigit() else "ul"
        items = []
        while i < len(lines) and lines[i].strip():
            t = lines[i].strip()
            m = re.match(r"^([-*+]|\d+[.)])\s+(.*)$", t)
            if m:
                items.append(m.group(2))
            elif items:
                items[-1] += " " + t
            else:
                break
            i += 1
        body.append("<%s>%s</%s>" % (tag, "".join("<li>%s</li>" % inline(x) for x in items), tag))
        continue
    elif s.startswith(">"):
        flush()
        quote = []
        while i < len(lines) and lines[i].strip().startswith(">"):
            quote.append(lines[i].strip()[1:].strip())
            i += 1
        body.append("<blockquote>%s</blockquote>" % inline(" ".join(quote)))
        continue
    else:
        para.append(s)
    i += 1
flush()

# Explicit colours for both schemes: Prow shows this page in a transparent iframe, so without a background the
# job page's own (often dark) theme shows through and dark text becomes unreadable.
css = (":root{color-scheme:light dark;--fg:#1f2328;--bg:#ffffff;--muted:#57606a;--line:#d0d7de;--soft:#f6f8fa;--link:#0969da}"
       "@media (prefers-color-scheme:dark){:root{--fg:#e6edf3;--bg:#0d1117;--muted:#9198a1;--line:#3d444d;--soft:#161b22;--link:#4493f8}}"
       "html{background:var(--bg)}body{background:var(--bg);color:var(--fg);font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;"
       "font-size:14px;line-height:1.5;margin:0;padding:16px;overflow-wrap:anywhere}"
       "h1,h2,h3,h4,h5,h6{color:var(--fg);margin:20px 0 8px;line-height:1.25}h1{font-size:1.6em}h2{font-size:1.35em;"
       "border-bottom:1px solid var(--line);padding-bottom:4px}h3{font-size:1.15em}a{color:var(--link)}"
       "table{border-collapse:collapse;margin:8px 0;display:block;max-width:100%;overflow-x:auto}"
       "th,td{border:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}th{background:var(--soft)}"
       "tbody tr:nth-child(even){background:var(--soft)}"
       "code{background:var(--soft);color:var(--fg);padding:1px 4px;border-radius:4px;font-size:90%}"
       "pre{background:var(--soft);padding:8px;overflow:auto}pre code{padding:0}"
       "hr{border:0;border-top:1px solid var(--line);margin:16px 0}"
       "blockquote{border-left:4px solid var(--line);margin:0;padding:0 12px;color:var(--muted)}")
with open(out, "w", encoding="utf-8") as f:
    f.write('<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>%s</title><style>%s</style></head><body>\n%s\n</body></html>\n'
            % (html.escape(title), css, "\n".join(body)))
PYEOF
}

# Ensure the report and session logs are copied to artifacts even if the script exits early
copy_reports() {
    if [[ -d "${WORKDIR:-}" ]]; then
        echo "Copying reports to artifact directory..."
        find "${WORKDIR}" -maxdepth 1 -name "*.md" -exec cp {} "${ARTIFACT_DIR}/" \; || true
        render_summary_html || true
    fi
    if [[ "${TRIAGE_POLICY:-devel}" == "ga" ]]; then
        ga_finalize_on_exit
    fi

    # Archive the full Claude session directory (including subagent logs) for session continuation.
    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        echo "Archiving Claude session logs..."
        if tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${CLAUDE_HOME}" projects/ 2>/dev/null; then
            touch "${SHARED_DIR}/claude-session-available"
        fi
    fi
}
trap copy_reports EXIT TERM INT

# --- GA helpers: junit, job history, finalizer ---
JUNIT_EXTRA_CASES=""
JUNIT_EXTRA_COUNT=0
JUNIT_EXTRA_FAILURES=0
JUNIT_WRITTEN=false
RECEIPT_WRITTEN=false
GA_EXIT_CODE=0
xml_escape() {
    # bash >= 5.2 would expand '&' in the replacement to the match; keep it literal on every version.
    shopt -u patsub_replacement 2>/dev/null || true
    local v="$1"
    v="${v//&/&amp;}"; v="${v//</&lt;}"; v="${v//>/&gt;}"; v="${v//\"/&quot;}"
    printf '%s' "${v}"
}
junit_case() {
    # junit_case <name> <ok:true|false> <message>
    local name msg
    name="$(xml_escape "${PHASE_PREFIX} $1")"
    msg="$(xml_escape "${3:-}")"
    JUNIT_EXTRA_COUNT=$(( JUNIT_EXTRA_COUNT + 1 ))
    if [[ "$2" == "true" ]]; then
        JUNIT_EXTRA_CASES+="  <testcase name=\"${name}\" time=\"0\"/>
"
    else
        JUNIT_EXTRA_FAILURES=$(( JUNIT_EXTRA_FAILURES + 1 ))
        JUNIT_EXTRA_CASES+="  <testcase name=\"${name}\" time=\"0\">
    <failure message=\"${msg}\">${msg}</failure>
  </testcase>
"
    fi
}

write_extra_junit() {
    # Standalone junit for paths that never reach the duty junit section (tripwire, early failures).
    cat > "${ARTIFACT_DIR}/junit_claude-ci.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${JUNIT_EXTRA_COUNT}" failures="${JUNIT_EXTRA_FAILURES}" time="0">
${JUNIT_EXTRA_CASES}</testsuite>
EOF
    JUNIT_WRITTEN=true
    echo "JUnit XML written to ${ARTIFACT_DIR}/junit_claude-ci.xml"
}

# Job history location: a periodic's runs live under logs/<job>/ in the results bucket; a rehearsal (the
# periodic run as a presubmit of an openshift/release PR) lives under pr-logs/pull/<org>_<repo>/<pr>/<job>/
# in the public bucket. Reading the right place lets chained rehearsals exercise the receipt/baseline path.
if [[ -n "${PULL_NUMBER:-}" ]]; then
    HISTORY_BUCKET="${GCS_BUCKET_PR_LOGS:-test-platform-results-public}"
    HISTORY_PREFIX="pr-logs/pull/${REPO_OWNER:-openshift}_${REPO_NAME:-release}/${PULL_NUMBER}"
else
    HISTORY_BUCKET="${GCS_BUCKET}"
    HISTORY_PREFIX="logs"
fi
history_url() {
    # history_url <job-name> -> gs:// prefix holding that job's runs
    printf 'gs://%s/%s/%s' "${HISTORY_BUCKET}" "${HISTORY_PREFIX}" "$1"
}

latest_preceding_attempt() {
    # latest_preceding_attempt [job-name]: prints the greatest run id of that job (default: this job) in GCS
    # that is strictly below the current build, or nothing. A listing that fails is discarded entirely
    # (partial output must never select a run).
    local job="${1:-${JOB_NAME:-}}" listing prefix
    prefix="$(history_url "${job}")/"
    if ! listing="$(gcloud storage ls "${prefix}" 2>/dev/null)"; then
        return 0
    fi
    printf '%s\n' "${listing}" \
        | sed -E 's#/+$##; s#.*/##' \
        | grep -E '^[0-9]+$' \
        | awk -v b="${BUILD_ID:-0}" 'length($0) < length(b) || (length($0) == length(b) && $0 < b)' \
        | sort -n | tail -1 || true
}

fetch_prev_artifact() {
    # fetch_prev_artifact <run-id> <artifact-name> <dest> [job-name]; non-zero when absent.
    local run="$1" name="$2" dest="$3" job="${4:-${JOB_NAME:-}}"
    gcloud storage cp \
        "$(history_url "${job}")/${run}/artifacts/*/openshift-claude-bulk-triage/artifacts/${name}" \
        "${dest}" >/dev/null 2>&1
}

PROW_RUN_URL="https://prow.ci.openshift.org/view/gs/${HISTORY_BUCKET}/${HISTORY_PREFIX}/${JOB_NAME:-unknown-job}/${BUILD_ID:-0}"
PREV_RUN=""
MODE_EFFECTIVE="${WRITE_MODE_REQUESTED}"
MODE_REASON=""
DECISION_LINE=""
DECISION="configured"
DECISION_ORIGIN=""
BASELINE_ARG="none"
read -r -a TRIAGE_VIEWS_ARR <<< "${TRIAGE_VIEWS}"
PREPASS_INVENTORY_ARGS=()
if [[ -n "${TRIAGE_INVENTORY_FILE}" ]]; then
    PREPASS_INVENTORY_ARGS=(--inventory "${TRIAGE_INVENTORY_FILE}" --no-oracle)
fi
# gcloud CLI does not read GOOGLE_APPLICATION_CREDENTIALS by itself; point it at the mounted SA key.
if [[ -f "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${GOOGLE_APPLICATION_CREDENTIALS}"
fi

write_receipt_now() {
    # write_receipt_now <mode_effective> — uses whatever audit files exist (unknown placeholders otherwise).
    local mode="$1" jira="${ARTIFACT_DIR}/jira-creations.json" sippy="${ARTIFACT_DIR}/sippy-catalog-diff.json"
    [[ -s "${jira}" ]] || printf '{"status": "unknown", "count": null, "error": "run ended before the Jira audit"}\n' > "${jira}"
    [[ -s "${sippy}" ]] || printf '{"status": "unknown", "error": "run ended before the Sippy catalogue diff"}\n' > "${sippy}"
    local extra=()
    [[ -n "${PREV_RUN}" ]] && extra+=(--previous-run "${PREV_RUN}")
    if [[ "${DECISION}" == "report" && -n "${DECISION_ORIGIN}" ]]; then
        extra+=(--downgrade-origin "${DECISION_ORIGIN}" --downgrade-reason "${MODE_REASON}")
        # per-origin reasons are copied from the receipt we inherited from (best-effort, never blocking)
        [[ -s "${WORKDIR:-}/previous-receipt.json" ]] && extra+=(--previous-receipt "${WORKDIR}/previous-receipt.json")
    fi
    if python3 "${AIH_SCRIPTS_DIR}/audit.py" receipt-write --out "${ARTIFACT_DIR}/runner-receipt.json" \
        --run-id "${BUILD_ID:-local}" --mode-requested "${WRITE_MODE_REQUESTED}" --mode-effective "${mode}" \
        --jira-creations "${jira}" --sippy-diff "${sippy}" ${extra[@]+"${extra[@]}"}; then
        RECEIPT_WRITTEN=true
        return 0
    fi
    return 1
}

ga_finalize_on_exit() {
    # Runs from the EXIT trap: guarantees a receipt and a junit exist, and that JSON artifacts reach $ARTIFACT_DIR.
    for f in prepass.json triage-manifest.json; do
        if [[ -d "${WORKDIR:-}" && -s "${WORKDIR}/${f}" && ! -s "${ARTIFACT_DIR}/${f}" ]]; then
            cp "${WORKDIR}/${f}" "${ARTIFACT_DIR}/${f}" || true
        fi
    done
    if [[ "${TRIAGE_ANALYSIS:-full}" != "quick" && "${RECEIPT_WRITTEN:-false}" != "true" ]]; then
        echo "Run ended early: writing a failure receipt (next run stays in report mode)."
        write_receipt_now report || true
    fi
    if [[ "${JUNIT_WRITTEN:-false}" != "true" ]]; then
        if [[ "${JUNIT_EXTRA_COUNT}" -eq 0 ]]; then
            junit_case "GA: run completed" false "the runner exited before producing its results"
        fi
        write_extra_junit || true
    fi
}

if [[ "${TRIAGE_POLICY}" == "ga" || "${TRIAGE_ANALYSIS}" == "quick" ]]; then
    PREV_RUN="$(latest_preceding_attempt)"
    if [[ -z "${PREV_RUN}" ]]; then
        echo "No preceding attempt found in $(history_url "${JOB_NAME:-}") (or job history unreadable); baseline none."
    else
        echo "Latest preceding attempt: ${PREV_RUN}"
    fi
fi

if [[ "${TRIAGE_ANALYSIS}" == "quick" ]]; then
    # Tripwire never invokes the agent and never writes, whatever the policy.
    echo "Tripwire mode: deterministic pre-pass over the last 24h, no LLM call, no writes."
    PREV_STATUS_ARG="none"
    if [[ -n "${PREV_RUN}" ]] && fetch_prev_artifact "${PREV_RUN}" burst-status.json "${WORKDIR}/previous-burst-status.json"; then
        PREV_STATUS_ARG="${WORKDIR}/previous-burst-status.json"
    fi
    echo "Previous status: ${PREV_STATUS_ARG}"
    # Growth of known clusters is judged against the latest full-analysis manifest (a different job): derive its
    # name from ours unless given explicitly.
    BASELINE_JOB="${TRIAGE_BASELINE_JOB:-${JOB_NAME/cr-burst-tripwire/bulk-triage-ga}}"
    FULL_BASELINE_ARG="none"
    FULL_RUN=""
    if [[ "${TRIAGE_BASELINE}" == "auto" && -n "${BASELINE_JOB}" ]]; then
        FULL_RUN="$(latest_preceding_attempt "${BASELINE_JOB}")"
        if [[ -n "${FULL_RUN}" ]] && fetch_prev_artifact "${FULL_RUN}" triage-manifest.json "${WORKDIR}/full-baseline.json" "${BASELINE_JOB}"; then
            FULL_BASELINE_ARG="${WORKDIR}/full-baseline.json"
        fi
    fi
    echo "Full-analysis baseline: ${FULL_BASELINE_ARG}${FULL_RUN:+ (run ${FULL_RUN} of ${BASELINE_JOB})}"
    TRIPWIRE_OK=true
    python3 "${AIH_SCRIPTS_DIR}/prepass.py" --tripwire --views "${TRIAGE_VIEWS_ARR[@]}" \
        --window-hours 24 --previous-status "${PREV_STATUS_ARG}" --baseline "${FULL_BASELINE_ARG}" --run-id "${BUILD_ID:-local}" \
        ${PREPASS_INVENTORY_ARGS[@]+"${PREPASS_INVENTORY_ARGS[@]}"} --out "${ARTIFACT_DIR}/burst-status.json" || TRIPWIRE_OK=false
    if [[ "${TRIPWIRE_OK}" == "true" && -s "${ARTIFACT_DIR}/burst-status.json" ]]; then
        junit_case "tripwire: burst-status.json produced" true ""
        echo "Tripwire triggers: $(jq -r '.triggers | length' "${ARTIFACT_DIR}/burst-status.json" 2>/dev/null || echo unknown)"
    else
        junit_case "tripwire: burst-status.json produced" false "prepass.py --tripwire failed or produced no output"
    fi
    write_extra_junit
    trap - EXIT TERM INT
    render_summary_html || true
    if [[ "${JUNIT_EXTRA_FAILURES}" -gt 0 ]]; then exit 1; fi
    exit 0
fi

if [[ "${TRIAGE_POLICY}" == "ga" ]]; then
    # Receipt check (independent of TRIAGE_BASELINE): the latest preceding attempt's audit can force report mode.
    RECEIPT_PATH="/nonexistent/runner-receipt.json"
    if [[ -n "${PREV_RUN}" ]] && fetch_prev_artifact "${PREV_RUN}" runner-receipt.json "${WORKDIR}/previous-receipt.json"; then
        RECEIPT_PATH="${WORKDIR}/previous-receipt.json"
    fi
    DECIDE_ARGS=(receipt-decide --receipt "${RECEIPT_PATH}")
    if [[ -n "${TRIAGE_ACK_RECEIPT}" ]]; then DECIDE_ARGS+=(--ack "${TRIAGE_ACK_RECEIPT}"); fi
    DECISION_LINE="$(python3 "${AIH_SCRIPTS_DIR}/audit.py" "${DECIDE_ARGS[@]}" 2>/dev/null || printf 'report\t\treceipt-decide failed')"
    # Exact three-field parse (IFS-based read would collapse an empty origin field).
    DECISION="${DECISION_LINE%%$'\t'*}"
    DECISION_REST="${DECISION_LINE#*$'\t'}"
    DECISION_ORIGIN="${DECISION_REST%%$'\t'*}"
    MODE_REASON="${DECISION_REST#*$'\t'}"
    [[ "${DECISION_LINE}" == *$'\t'* ]] || { DECISION_ORIGIN=""; MODE_REASON=""; }
    DECISION="${DECISION:-report}"
    if [[ "${DECISION}" == "report" ]]; then
        MODE_EFFECTIVE="report"
        echo "Write mode forced to report by the previous receipt: ${MODE_REASON}"
    elif [[ -n "${MODE_REASON}" ]]; then
        echo "Receipt decision: ${MODE_REASON}"
    fi
    echo "Effective write mode: ${MODE_EFFECTIVE} (requested ${WRITE_MODE_REQUESTED}, TRIAGE_WRITES=${TRIAGE_WRITES})"

    if [[ "${TRIAGE_BASELINE}" == "auto" && -n "${PREV_RUN}" ]] && fetch_prev_artifact "${PREV_RUN}" triage-manifest.json "${WORKDIR}/baseline-manifest.json"; then
        BASELINE_ARG="${WORKDIR}/baseline-manifest.json"
    fi
    echo "Baseline: ${BASELINE_ARG}"

    # Sippy triage catalogue before the agent runs (authoritative record of Sippy writes).
    python3 "${AIH_SCRIPTS_DIR}/audit.py" snapshot --out "${ARTIFACT_DIR}/sippy-triages-before.json" || true

    echo "Running the deterministic pre-pass..."
    PREPASS_OK=true
    python3 "${AIH_SCRIPTS_DIR}/prepass.py" --views "${TRIAGE_VIEWS_ARR[@]}" --baseline "${BASELINE_ARG}" \
        --token-env DPCR_TOKEN --run-id "${BUILD_ID:-local}" ${PREPASS_INVENTORY_ARGS[@]+"${PREPASS_INVENTORY_ARGS[@]}"} \
        --out "${WORKDIR}/prepass.json" || PREPASS_OK=false
    if [[ "${PREPASS_OK}" == "true" && -s "${WORKDIR}/prepass.json" ]]; then
        cp "${WORKDIR}/prepass.json" "${ARTIFACT_DIR}/prepass.json"
        junit_case "GA: pre-pass produced prepass.json" true ""
        echo "Pre-pass clusters: $(jq -r '.clusters | length' "${WORKDIR}/prepass.json" 2>/dev/null || echo unknown)"
    else
        junit_case "GA: pre-pass produced prepass.json" false "prepass.py failed; the agent cannot run without an inventory"
        exit 1   # the EXIT trap writes the failure receipt and the junit
    fi
fi

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"

# agentic-ci manages OTEL collector lifecycle per invocation; collect JSONL after each run
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob WebFetch WebSearch Task Skill"

agentic_ci() {
    local agentic_args=()
    local timeout_seconds=""
    while true; do
        case "${1:-}" in
            --no-streaming) agentic_args+=("$1"); shift ;;
            --timeout) timeout_seconds="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local prompt="$1"; shift
    local cmd=(
        agentic-ci run
        --backend local
        --harness claude-code
        --model "${CLAUDE_MODEL}"
        --workdir "${WORKDIR}"
        "${agentic_args[@]+"${agentic_args[@]}"}"
        "${prompt}"
        --
        --permission-mode default
        --allowedTools "${ALLOWED_TOOLS}"
        --verbose
        "$@"
    )
    if [[ -n "${timeout_seconds}" ]]; then
        timeout "${timeout_seconds}" "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
    local rc=$?
    for f in /tmp/agentic-ci-run.*/claude-otel.jsonl; do
        [ -f "$f" ] && cat "$f" >> "${OTEL_LOG}"
    done
    rm -rf /tmp/agentic-ci-run.*
    return $rc
}

SYSTEM_PROMPT="You are a diligent senior OpenShift release engineer on Component Readiness triage duty.

**CRITICAL**: You have many ci skills at your disposal. You MUST load the relevant skills using the Skill tool BEFORE you begin any work. Do NOT improvise or guess. This applies equally to subagents: instruct every subagent to review its available skills and load the appropriate ones before beginning its investigation.

**WRITE SCOPE — READ CAREFULLY**: You have write credentials for both Sippy and JIRA. Sippy: a DPCR bearer token is in the environment variable \$DPCR_TOKEN — you ARE authorized to create and update Component Readiness triage records (via the ci:triage-regression skill — pass it as --token \"\$DPCR_TOKEN\") and to run the authenticated reevaluate symptom probe in dry-run (detection) mode; use \$DPCR_TOKEN directly rather than running 'oc login'. JIRA: you act as the openshift-qse-bot-managers service account (\$JIRA_USERNAME / \$JIRA_API_TOKEN) ${JIRA_WRITE_SCOPE} Every JIRA issue or comment you create MUST end with the AI-attribution footer as its own visually marked block (an ADF rule followed by a note panel containing 'AI-generated content: filed by AI as part of Component Readiness triage duty. Please verify before acting on it.'); after add-jira-triage-link runs, verify that footer is still the final block. You are NOT authorized to: transition, resolve, or close JIRA issues; set release blockers; or create/modify Sippy labels or symptoms — capture each of those as a recommendation in the report. Do NOT post anything to Slack or anywhere else."

PROMPT="Load and follow the ci:bulk-triage-regressions skill for view '${TRIAGE_VIEW}' covering ${COMPONENTS_CLAUSE}. Execute Phases 1-5 fully${EXISTING_ONLY_FLAG}. You ARE authorized to create or extend Sippy triage records (use \$DPCR_TOKEN), ${JIRA_BUG_SCOPE}to comment on existing bugs, and to append the Component Readiness triage link to each bug (ci:add-jira-triage-link) — every JIRA issue or comment you create must carry the AI-attribution footer. Record a recommendation in the report instead of performing the action for: release blockers, new Sippy symptoms/labels, and any JIRA transition/resolve/close (these need human confirmation).

Write the complete duty report as GitHub-flavored markdown to ${WORKDIR}/${REPORT_FILE}. The report must contain: the untriaged-regression inventory table, the bucket list with member regression IDs and evidence (error signatures, failure stage, representative run links, suspect PRs), the recommended disposition per bucket (extend triage <id> / link to <JIRA> / file new bug against <component> with a draft summary), deliberately-untriaged leftovers with reasons, and cross-cutting observations. Every claim must cite artifact paths or run URLs.${EXISTING_ONLY_REPORT}"

if [[ "${TRIAGE_POLICY}" == "ga" ]]; then
    GA_WRITE_CLAUSE="You ARE authorized, in --write-mode auto, to create or extend Sippy triage records (use \$DPCR_TOKEN) and to perform the JIRA writes allowed by ${GA_POLICY_DOC} (ci:add-jira-triage-link and the backport-candidate comment) — and nothing else."
    if [[ "${MODE_EFFECTIVE}" == "report" ]]; then
        GA_WRITE_CLAUSE="This run is --write-mode report: you are NOT authorized to perform ANY write to Sippy or JIRA (no triage records, no triage links, no comments). Record every intended action in the manifest with status skipped-report-mode."
    fi
    SYSTEM_PROMPT="${SYSTEM_PROMPT}

**GA POLICY**: This is a GA (released versions) run under --policy ${GA_POLICY_FLAG} --write-mode ${MODE_EFFECTIVE}. ${GA_WRITE_CLAUSE} Phase 0 is already done by the runner: ${WORKDIR}/prepass.json is the complete inventory and cluster list — do not re-derive clusters and do not call the Sippy list/details/related-triages APIs for inventory. Analyse clusters in file order (HIGH first) under the time budget. A symptom_probe.status other than ok is UNKNOWN, never 'no symptoms matched'. Follow ${GA_POLICY_DOC} for everything else."

    PROMPT="Load and follow the ci:bulk-triage-regressions skill with --policy ${GA_POLICY_FLAG} --write-mode ${MODE_EFFECTIVE} --views ${TRIAGE_VIEWS} covering ${COMPONENTS_CLAUSE}, with --existing-only. Phase 0 is complete: read ${WORKDIR}/prepass.json and treat its clusters as the batch. Execute Phases 1-5 per ${GA_POLICY_DOC}. ${GA_WRITE_CLAUSE}

Write ${WORKDIR}/triage-manifest.json by assembling dispositions.json, actions.json and extra.json as the policy describes and running ${AIH_SCRIPTS_DIR}/manifest.py merge --prepass ${WORKDIR}/prepass.json ... --out ${WORKDIR}/triage-manifest.json, then ${AIH_SCRIPTS_DIR}/manifest.py validate ${WORKDIR}/triage-manifest.json (it must exit 0; fix the data, never weaken it). Write the complete duty report as GitHub-flavored markdown to ${WORKDIR}/${REPORT_FILE}: inventory per view, every cluster with its blast radius, disposition, evidence (own run links, artifact paths), bug decisions and action or proposed action, the watch list, catch-all admissions, backport candidates, unanalysed clusters, and cross-cutting observations. Every claim must cite artifact paths or run URLs.${EXISTING_ONLY_REPORT}"
fi

PHASE_ANALYSIS_START=$(date +%s)
CLAUDE_EXIT=0
agentic_ci --timeout 10800 \
    "${PROMPT}" \
    --max-turns 250 \
    --append-system-prompt "${SYSTEM_PROMPT}" \
    || CLAUDE_EXIT=$?

# If Claude timed out (exit 124), nudge it to wrap up with a shorter timeout
PHASE_NUDGE_START=$(date +%s)
NUDGE_EXIT=0
if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    echo ""
    echo "Claude timed out. Nudging to wrap up..."
    agentic_ci --timeout 600 \
        "I think you got stuck and hit the timeout. Please wrap up now with whatever data you have collected so far: write the duty report to ${WORKDIR}/${REPORT_FILE} immediately, marking incomplete buckets as 'analysis incomplete (timeout)'." \
        --continue \
        --max-turns 20 \
        || NUDGE_EXIT=$?
fi
PHASE_NUDGE_DURATION=$(( $(date +%s) - PHASE_NUDGE_START ))
PHASE_ANALYSIS_DURATION=$(( $(date +%s) - PHASE_ANALYSIS_START ))

if [[ "${TRIAGE_POLICY}" == "ga" ]]; then
    RUN_END="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    # Agent outcome (a timeout is handled by the duty junit cases; any other failure is a GA-run failure).
    if [[ "${CLAUDE_EXIT}" -eq 0 || "${CLAUDE_EXIT}" -eq 124 ]]; then
        junit_case "GA: agent completed" true ""
    else
        junit_case "GA: agent completed" false "agentic-ci exited with code ${CLAUDE_EXIT}"
    fi
    # Sippy triage catalogue after the agent; diff against the declared actions.
    python3 "${AIH_SCRIPTS_DIR}/audit.py" snapshot --out "${ARTIFACT_DIR}/sippy-triages-after.json" || true
    SIPPY_DIFF_STATUS="unknown"
    if [[ -s "${ARTIFACT_DIR}/sippy-triages-before.json" && -s "${ARTIFACT_DIR}/sippy-triages-after.json" ]]; then
        MANIFEST_FOR_DIFF="${WORKDIR}/triage-manifest.json"
        [[ -s "${MANIFEST_FOR_DIFF}" ]] || MANIFEST_FOR_DIFF="/dev/null"
        SIPPY_DIFF_STATUS="$(python3 "${AIH_SCRIPTS_DIR}/audit.py" diff --before "${ARTIFACT_DIR}/sippy-triages-before.json" \
            --after "${ARTIFACT_DIR}/sippy-triages-after.json" --manifest "${MANIFEST_FOR_DIFF}" \
            --out "${ARTIFACT_DIR}/sippy-catalog-diff.json" 2>/dev/null || echo unknown)"
    fi
    if [[ ! -s "${ARTIFACT_DIR}/sippy-catalog-diff.json" ]]; then
        printf '{"status": "unknown", "error": "catalogue snapshots missing or diff failed"}\n' > "${ARTIFACT_DIR}/sippy-catalog-diff.json"
    fi
    if [[ "${SIPPY_DIFF_STATUS}" == "match" ]]; then
        junit_case "GA: Sippy writes match the report" true ""
    else
        junit_case "GA: Sippy writes match the report" false "Sippy catalogue diff status: ${SIPPY_DIFF_STATUS}"
    fi
    # Account-wide JIRA creations in the run window (shared service account: attribution is best-effort).
    python3 "${AIH_SCRIPTS_DIR}/audit.py" jql --start "${RUN_START}" --end "${RUN_END}" \
        --reporter "${JIRA_USERNAME:-unknown}" --out "${ARTIFACT_DIR}/jira-creations.json" || true
    JIRA_CREATED="$(jq -r '.count // "unknown"' "${ARTIFACT_DIR}/jira-creations.json" 2>/dev/null || echo unknown)"
    JIRA_STATUS="$(jq -r '.status // "unknown"' "${ARTIFACT_DIR}/jira-creations.json" 2>/dev/null || echo unknown)"
    JIRA_TRUNCATED="$(jq -r '.truncated // false' "${ARTIFACT_DIR}/jira-creations.json" 2>/dev/null || echo true)"
    if [[ "${JIRA_STATUS}" == "ok" && "${JIRA_CREATED}" == "0" && "${JIRA_TRUNCATED}" == "false" ]]; then
        junit_case "GA: no Jira issues created by the job" true ""
    else
        junit_case "GA: no Jira issues created by the job" false "account-wide creations in window: ${JIRA_CREATED} (status ${JIRA_STATUS}, truncated ${JIRA_TRUNCATED}; shared account — see jira-creations.json)"
    fi
    echo "Jira creations in window (account-wide): ${JIRA_CREATED} (status ${JIRA_STATUS}, truncated ${JIRA_TRUNCATED}); Sippy diff: ${SIPPY_DIFF_STATUS}"
    # Permissions observation (transparency only, never a gate).
    python3 "${AIH_SCRIPTS_DIR}/audit.py" permissions --out "${ARTIFACT_DIR}/jira-permissions.json" || true
    [[ -s "${ARTIFACT_DIR}/jira-permissions.json" ]] || printf '{"status": "unknown"}\n' > "${ARTIFACT_DIR}/jira-permissions.json"
    # Manifest: inject the runner-owned audit and run metadata, then validate and publish.
    if [[ -s "${WORKDIR}/triage-manifest.json" ]]; then
        if python3 "${AIH_SCRIPTS_DIR}/manifest.py" finalize --manifest "${WORKDIR}/triage-manifest.json" \
            --out "${ARTIFACT_DIR}/triage-manifest.json" \
            --jira-creations "${ARTIFACT_DIR}/jira-creations.json" --sippy-diff "${ARTIFACT_DIR}/sippy-catalog-diff.json" \
            --permissions "${ARTIFACT_DIR}/jira-permissions.json" \
            --mode-requested "${WRITE_MODE_REQUESTED}" --mode-effective "${MODE_EFFECTIVE}" \
            --decision "${DECISION_LINE}" --job "${JOB_NAME:-unknown-job}" --run-id "${BUILD_ID:-local}" \
            --url "${PROW_RUN_URL}" --started "${RUN_START}" ${PREV_RUN:+--previous-run "${PREV_RUN}"} \
            --existing-only true 2> "${WORKDIR}/manifest-validate.err"; then
            junit_case "GA: manifest validates" true ""
        else
            [[ -s "${ARTIFACT_DIR}/triage-manifest.json" ]] || cp "${WORKDIR}/triage-manifest.json" "${ARTIFACT_DIR}/triage-manifest.json" || true
            junit_case "GA: manifest validates" false "manifest.py finalize/validate failed: $(head -c 400 "${WORKDIR}/manifest-validate.err")"
        fi
    else
        junit_case "GA: manifest validates" false "triage-manifest.json was not produced"
    fi
    # Receipt for the next run.
    if write_receipt_now "${MODE_EFFECTIVE}"; then
        junit_case "GA: receipt written" true ""
    else
        junit_case "GA: receipt written" false "audit.py receipt-write failed"
    fi
    if [[ "${JUNIT_EXTRA_FAILURES}" -gt 0 ]]; then
        GA_EXIT_CODE=1
    fi
fi

# Generate JUnit XML for timeout and phase duration tracking
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-ci.xml"
# The prefix contains quotes: escape it once for the hand-built XML attributes below.
PHASE_PREFIX_XML="$(xml_escape "${PHASE_PREFIX}")"
TIMEOUT_TESTCASE="${PHASE_PREFIX_XML} Claude should complete in a reasonable time"
REPORT_TESTCASE="${PHASE_PREFIX_XML} Claude should produce a triage duty report"

FAILURE_COUNT=0

if [[ "${CLAUDE_EXIT}" -eq 124 ]]; then
    if [[ "${NUDGE_EXIT}" -eq 0 ]] && [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
        TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>
  <testcase name=\"${TIMEOUT_TESTCASE} (recovery)\" time=\"${PHASE_NUDGE_DURATION}\"/>"
        FAILURE_COUNT=1
    else
        TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\">
    <failure message=\"Claude timed out.\">Claude exceeded the time limit and had to be nudged to wrap up.</failure>
  </testcase>
  <testcase name=\"${TIMEOUT_TESTCASE} (recovery)\" time=\"${PHASE_NUDGE_DURATION}\">
    <failure message=\"Claude failed to recover after nudge\">Claude was nudged to wrap up but did not produce a report (exit code: ${NUDGE_EXIT}).</failure>
  </testcase>"
        FAILURE_COUNT=2
    fi
    TIMEOUT_TEST_COUNT=2
else
    TIMEOUT_CASES="  <testcase name=\"${TIMEOUT_TESTCASE}\" time=\"${PHASE_ANALYSIS_DURATION}\"/>"
    TIMEOUT_TEST_COUNT=1
fi

if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
    REPORT_CASES="  <testcase name=\"${REPORT_TESTCASE}\" time=\"0\"/>"
else
    REPORT_CASES="  <testcase name=\"${REPORT_TESTCASE}\" time=\"0\">
    <failure message=\"No report generated\">Expected markdown report ${REPORT_FILE} was not produced.</failure>
  </testcase>"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Extract session metrics (cost, tokens, duration) for BigQuery
METRICS_CASE=""
METRICS_TEST_COUNT=0
METRICS_FILE="${ARTIFACT_DIR}/claude-session-metrics-autodl.json"
if [[ -f "${EXTRACT_METRICS}" ]] && [[ -f "${OTEL_LOG}" ]]; then
    METRICS_TEST_COUNT=1
    if python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${METRICS_FILE}"; then
        METRICS_CASE="  <testcase name=\"${PHASE_PREFIX_XML} Session metrics extraction\" time=\"0\"/>"

        # Append authoritative session usage to the markdown report. This must
        # happen post-session: the model cannot observe its own final token
        # totals while the session is still running.
        if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
            jq -r '.rows[0] | "
---

## Session usage

_Appended by the CI harness after the analysis session (extracted from OTEL telemetry)._

| Metric | Value |
|---|---|
| Model | \(.model) |
| Turns | \(.num_turns) |
| Tool calls | \(.total_tool_calls) |
| Subagents | \(.num_subagents) |
| Input tokens | \(.input_tokens) |
| Output tokens | \(.output_tokens) |
| Cache read tokens | \(.cache_read_input_tokens) |
| Cache creation tokens | \(.cache_creation_input_tokens) |
| Cache hit rate | \(.cache_hit_rate_pct)% |
| Total cost (USD) | \(.total_cost_usd) |
| Duration | \((.duration_ms | tonumber / 60000 * 10 | round / 10)) min |
"' "${METRICS_FILE}" >> "${WORKDIR}/${REPORT_FILE}" \
                || echo "Warning: failed to append session usage to the report."
        fi
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        METRICS_CASE="  <testcase name=\"${PHASE_PREFIX_XML} Session metrics extraction\" time=\"0\">
    <failure message=\"Failed to extract session metrics\">extract_metrics.py exited with an error. Check the output log.</failure>
  </testcase>"
    fi
fi

TEST_COUNT=$(( TIMEOUT_TEST_COUNT + 1 + METRICS_TEST_COUNT + JUNIT_EXTRA_COUNT ))
FAILURE_COUNT=$(( FAILURE_COUNT + JUNIT_EXTRA_FAILURES ))
TOTAL_DURATION=$(( PHASE_ANALYSIS_DURATION + PHASE_NUDGE_DURATION ))
cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-ci" tests="${TEST_COUNT}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${TIMEOUT_CASES}
${REPORT_CASES}
${METRICS_CASE}
${JUNIT_EXTRA_CASES}</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"
JUNIT_WRITTEN=true

if [[ -s "${WORKDIR}/${REPORT_FILE}" ]]; then
    echo "Triage analysis complete. Report: ${REPORT_FILE}"
else
    echo "ERROR: No markdown report was generated."
    exit 1
fi
if [[ "${TRIAGE_POLICY}" == "ga" && "${GA_EXIT_CODE}" -ne 0 ]]; then
    echo "ERROR: GA checks failed (see junit); exiting non-zero."
    exit "${GA_EXIT_CODE}"
fi
