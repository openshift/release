#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Init Model ==="

cat > "${SHARED_DIR}/trt-init-model.sh" << 'HEREDOC_EOF'
#!/bin/bash
# Model selection for TRT agent runs. Sourced by trt-telemetry.sh.

select_agent_model() {
    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-}" ]]; then
        printf '%s\n' "${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL}"
        return 0
    fi
    if [[ -n "${AGENT_MODEL:-}" ]]; then
        printf '%s\n' "${AGENT_MODEL}"
        return 0
    fi
    echo "ERROR: AGENT_MODEL is required. Set it on the step or pass MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL." >&2
    return 1
}

select_agent_harness() {
    case "$1" in
        gpt-*) printf '%s\n' codex ;;
        *) printf '%s\n' claude-code ;;
    esac
}

ensure_codex() {
    # gpt-6.1-sol entered the bundled catalog in rust-v0.159.1.
    # 0.164.0 lists it with guardian unset, so the CLI does not
    # substitute gpt-5.6-luna metadata.
    local version="0.164.0"
    local dest="${HOME}/.local/codex"
    local pin_file="${dest}/.codex-pin"
    if [[ -x "${dest}/bin/codex" && "$(cat "${pin_file}" 2>/dev/null || true)" == "${version}" ]]; then
        export PATH="${dest}/bin:${dest}/codex-path:${PATH}"
        return 0
    fi
    local lockdir="${dest}.installing"
    mkdir -p "${HOME}/.local"
    if ! mkdir "${lockdir}" 2>/dev/null; then
        local i
        for i in $(seq 1 360); do
            if [[ -x "${dest}/bin/codex" && "$(cat "${pin_file}" 2>/dev/null || true)" == "${version}" ]]; then
                export PATH="${dest}/bin:${dest}/codex-path:${PATH}"
                return 0
            fi
            sleep 1
        done
        echo "ERROR: Timed out waiting for Codex installation." >&2
        return 1
    fi
    local arch sha tarball
    case "$(uname -m)" in
        x86_64)
            arch="x86_64"
            sha="3ec55053109608d5038f7e50750f7d25f768dfd740fef071aa710e2559b63aac"
            ;;
        aarch64)
            arch="aarch64"
            sha="5918add6c7e9cf1e14a9af1b4c0f4bf1d24a43903faac26df5dc4c019ea91bd5"
            ;;
        *)
            echo "ERROR: Unsupported architecture for Codex: $(uname -m)" >&2
            rmdir "${lockdir}"
            return 1
            ;;
    esac
    tarball=$(mktemp)
    if ! curl -fsSL --retry 3 --retry-delay 5 \
        "https://github.com/openai/codex/releases/download/rust-v${version}/codex-package-${arch}-unknown-linux-musl.tar.gz" \
        -o "${tarball}"; then
        rm -f "${tarball}"
        rmdir "${lockdir}"
        echo "ERROR: Failed to download Codex ${version}." >&2
        return 1
    fi
    if ! echo "${sha}  ${tarball}" | sha256sum -c -; then
        rm -f "${tarball}"
        rmdir "${lockdir}"
        return 1
    fi
    rm -rf "${dest}"
    mkdir -p "${dest}"
    if ! tar -xzf "${tarball}" -C "${dest}"; then
        rm -f "${tarball}"
        rmdir "${lockdir}"
        echo "ERROR: Failed to unpack Codex ${version}." >&2
        return 1
    fi
    rm -f "${tarball}"
    if [[ ! -x "${dest}/bin/codex" ]]; then
        rmdir "${lockdir}"
        echo "ERROR: Codex ${version} package did not contain bin/codex." >&2
        return 1
    fi
    printf '%s\n' "${version}" > "${pin_file}"
    rmdir "${lockdir}"
    export PATH="${dest}/bin:${dest}/codex-path:${PATH}"
    echo "Using Codex ${version}."
}

load_openai_api_key() {
    local key_path="${OPENAI_API_KEY_PATH:-/var/run/codex-openai-api-key/token}"
    if [[ ! -s "${key_path}" ]]; then
        echo "ERROR: Codex API key file is missing or empty: ${key_path}." >&2
        return 1
    fi
    # Disable tracing before the secret is read so its value cannot reach logs.
    local restore_xtrace=false
    if [[ $- == *x* ]]; then
        restore_xtrace=true
        set +x
    fi
    OPENAI_API_KEY=$(<"${key_path}")
    export OPENAI_API_KEY
    if [[ -z "${OPENAI_API_KEY}" ]]; then
        if ${restore_xtrace}; then
            set -x
        fi
        echo "ERROR: Codex API key file is missing or empty: ${key_path}." >&2
        return 1
    fi
    if ${restore_xtrace}; then
        set -x
    fi
    echo "OpenAI API key loaded."
}

# Parallel eval cases are separate processes and must not share a Codex home.
# Calls in one process reuse one home so --continue can resume the session.
# Logins take this lock. The caller unsets OPENAI_API_KEY before agentic-ci so
# the child does not log in again. flock releases the lock if this process dies.
login_codex() {
    local lockfile="${HOME}/.local/codex.login.lock"
    local err rc=0
    local restore_xtrace=false
    mkdir -p "${HOME}/.local"
    if ! command -v flock >/dev/null 2>&1; then
        echo "ERROR: flock is required for Codex login." >&2
        return 1
    fi
    exec 200>"${lockfile}"
    if ! flock -w 120 200; then
        exec 200>&-
        echo "ERROR: timed out waiting for the Codex login lock." >&2
        return 1
    fi
    if [[ $- == *x* ]]; then
        restore_xtrace=true
        set +x
    fi
    err=$(mktemp)
    if ! printf '%s' "${OPENAI_API_KEY}" | timeout 60 codex login --with-api-key >"${err}" 2>&1; then
        echo "ERROR: codex login --with-api-key failed." >&2
        if [[ -z "${OPENAI_API_KEY}" ]] || ! grep -F -q -- "${OPENAI_API_KEY}" "${err}"; then
            cat "${err}" >&2
        fi
        rc=1
    fi
    rm -f "${err}"
    if ${restore_xtrace}; then
        set -x
    fi
    exec 200>&-
    return "${rc}"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/trt-init-model.sh"
echo "Model helper written to ${SHARED_DIR}/trt-init-model.sh"

cat > "${SHARED_DIR}/trt-telemetry.sh" << 'HEREDOC_EOF'
#!/bin/bash
# TRT agentic telemetry helpers. Source from jira-solver / review-responder:
#   source "${SHARED_DIR}/trt-telemetry.sh"

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
if [[ "${EVAL_MODE:-}" == "true" ]]; then
    OTEL_LOG="${SHARED_DIR}/claude-otel.jsonl"
else
    OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"
fi

if [[ -f "${SHARED_DIR}/github-app-auth.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/github-app-auth.sh"
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/trt-init-model.sh"

append_codex_prefix_rule() {
    local rules_file=$1
    local justification=$2
    shift 2
    [[ $# -gt 0 ]] || return 0
    local pattern="" token quoted
    for token in "$@"; do
        quoted=${token//\\/\\\\}
        quoted=${quoted//\"/\\\"}
        pattern+="\"${quoted}\", "
    done
    pattern=${pattern%, }
    quoted=${justification//\\/\\\\}
    quoted=${quoted//\"/\\\"}
    cat >> "${rules_file}" <<EOF
prefix_rule(
    pattern = [${pattern}],
    decision = "forbidden",
    justification = "${quoted}",
)
EOF
}

# Best-effort credential denies. A Codex prefix rule matches an ordered argv
# prefix only, so this is non-exhaustive: another reader, a flag before the
# path, or a different spelling still runs. The system prompt also tells the
# agent not to read these files. A compromised agent can still reach them.
append_codex_command_needle_rules() {
    local rules_file=$1
    local spec=$2
    local cmd=$3
    local needle=$4
    local path
    local -a paths=("${needle}")
    if [[ "${needle}" != /* && "${needle}" != ./* ]]; then
        paths+=("./${needle}")
    fi
    if [[ "${needle}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        paths+=("\$${needle}" "\${${needle}}")
    fi
    if [[ -n "${SHARED_DIR:-}" && "${needle}" != /* ]]; then
        paths+=("${SHARED_DIR}/${needle}")
    fi
    case "${needle}" in
        *github-token*)
            paths+=(
                /var/run/github-token/token
                /var/run/github-token/app-id
                /var/run/github-token/private-key
            )
            ;;
        *claude-code-service-account*|*google-token*)
            paths+=(
                /var/run/claude-code-service-account/google-token
                /var/run/claude-code-service-account/claude-prow
            )
            ;;
        *codex-openai-api-key*|*auth.json*)
            paths+=(/var/run/codex-openai-api-key/token)
            if [[ -n "${CODEX_HOME:-}" ]]; then
                paths+=("${CODEX_HOME}/auth.json")
            fi
            ;;
    esac
    for path in "${paths[@]}"; do
        append_codex_prefix_rule "${rules_file}" "${spec}" "${cmd}" "${path}"
    done
}

translate_disallowed_tool() {
    local rules_file=$1
    local spec=$2
    local inner prefix needle cmd translated=false
    local -a parts tokens
    if [[ "${spec}" == Bash\(*\) ]]; then
        inner=${spec#Bash(}
        inner=${inner%)}
        IFS='*' read -r -a parts <<< "${inner}"
        prefix=${parts[0]}
        read -r -a tokens <<< "${prefix}"
        if [[ ${#tokens[@]} -eq 0 ]]; then
            echo "ERROR: Codex cannot translate tool restriction: ${spec}" >&2
            return 1
        fi
        if [[ ${#parts[@]} -le 2 && -z "${parts[1]:-}" ]]; then
            append_codex_prefix_rule "${rules_file}" "${spec}" "${tokens[@]}"
            return 0
        fi
        # A glob in the middle cannot be a prefix rule. Forbidding every
        # git config is stricter than the spec and still enforces it.
        if [[ "${prefix}" == "git config" ]]; then
            append_codex_prefix_rule "${rules_file}" "${spec}" "${tokens[@]}"
            return 0
        fi
        # Shell wrappers and other multi-token commands with a glob in the
        # middle do not match a [cmd, needle] prefix. Refuse the run rather
        # than publish a rule that does not apply.
        if [[ ${#tokens[@]} -gt 1 ]]; then
            echo "ERROR: Codex cannot translate tool restriction: ${spec}" >&2
            return 1
        fi
        for needle in "${parts[@]:1}"; do
            [[ -n "${needle}" ]] || continue
            append_codex_command_needle_rules "${rules_file}" "${spec}" "${tokens[0]}" "${needle}"
            translated=true
        done
        if [[ "${translated}" != true ]]; then
            echo "ERROR: Codex cannot translate tool restriction: ${spec}" >&2
            return 1
        fi
        return 0
    fi
    if [[ "${spec}" == Read\(*\) ]]; then
        inner=${spec#Read(}
        inner=${inner%)}
        inner=${inner%/\*\*}
        inner=${inner%/\*}
        inner=${inner%/}
        if [[ "${inner}" == //* ]]; then
            inner=${inner#/}
        fi
        if [[ -z "${inner}" ]]; then
            echo "ERROR: Codex cannot translate tool restriction: ${spec}" >&2
            return 1
        fi
        for cmd in cat head sed od; do
            append_codex_command_needle_rules "${rules_file}" "${spec}" "${cmd}" "${inner}"
        done
        return 0
    fi
    echo "WARNING: Codex cannot enforce tool restriction: ${spec}" >&2
    return 0
}

write_codex_disallowed_rules() {
    local rules_dir="${CODEX_HOME}/rules"
    local rules_file="${rules_dir}/trt-disallowed.rules"
    local spec rc=0
    if [[ -z "${CODEX_HOME:-}" ]]; then
        echo "ERROR: CODEX_HOME is required to write Codex tool restrictions." >&2
        return 1
    fi
    mkdir -p "${rules_dir}" || return 1
    : > "${rules_file}" || return 1
    for spec in "$@"; do
        translate_disallowed_tool "${rules_file}" "${spec}" || rc=1
    done
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: Codex tool restrictions were not applied." >&2
        return 1
    fi
    echo "Applied Codex tool restrictions in ${rules_file}"
}

exclude_codex_from_worktree() {
    local git_dir exclude
    git -C "${WORKDIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    git_dir=$(git -C "${WORKDIR}" rev-parse --absolute-git-dir) || return 0
    exclude="${git_dir}/info/exclude"
    mkdir -p "$(dirname "${exclude}")"
    if [[ -f "${exclude}" ]] && grep -qxF '.codex/' "${exclude}"; then
        return 0
    fi
    printf '%s\n' '.codex/' >> "${exclude}"
}

codex_home_cleanup() {
    local status=$?
    if [[ -n "${CODEX_HOME:-}" ]]; then
        rm -rf "${CODEX_HOME}"
    fi
    if [[ -n "${CODEX_HOME_PREVIOUS_EXIT_CMD:-}" ]]; then
        eval "${CODEX_HOME_PREVIOUS_EXIT_CMD}" || true
    fi
    exit "${status}"
}

prepare_codex_home() {
    if [[ -n "${CODEX_HOME:-}" && -d "${CODEX_HOME}" ]]; then
        return 0
    fi
    CODEX_HOME=$(mktemp -d /tmp/codex-home.XXXXXX) || return 1
    export CODEX_HOME
    [[ -n "${CODEX_HOME_CLEANUP_INSTALLED:-}" ]] && return 0
    CODEX_HOME_CLEANUP_INSTALLED=1
    local previous quoted
    previous=$(trap -p EXIT || true)
    CODEX_HOME_PREVIOUS_EXIT_CMD=""
    if [[ -n "${previous}" ]]; then
        quoted=${previous#trap -- }
        quoted=${quoted% EXIT}
        CODEX_HOME_PREVIOUS_EXIT_CMD=$(eval "printf '%s' ${quoted}")
    fi
    trap codex_home_cleanup EXIT
}

agentic_ci() {
    # Installation tokens last 1h; mint a fresh one before each long child.
    if declare -F refresh_github_tokens >/dev/null 2>&1; then
        refresh_github_tokens || echo "WARNING: GitHub App token refresh failed; continuing with existing tokens"
    fi
    local timeout_seconds=""
    local extra_args=()
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --timeout) timeout_seconds="$2"; shift 2 ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done
    local prompt="$1"; shift
    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-}" ]]; then
        echo "Applying Gangway override: AGENT_MODEL=${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL}"
    fi
    local model harness
    model=$(select_agent_model) || return $?
    harness=$(select_agent_harness "${model}") || return $?
    echo "Harness: ${harness} | Model: ${model}"

    local harness_args=()
    if [[ "${harness}" == "codex" ]]; then
        if [[ -z "${WORKDIR:-}" ]]; then
            echo "ERROR: WORKDIR is required for a Codex run." >&2
            return 2
        fi
        local codex_resume=false
        local system_prompt_file=""
        local settings_file=""
        local settings_denied=""
        local spec
        local -a denied=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --output-format|--max-turns)
                    shift 2
                    ;;
                --permission-mode|--allowedTools)
                    echo "ERROR: Codex cannot enforce $1. Refusing to run without that restriction." >&2
                    return 2
                    ;;
                --settings)
                    settings_file="$2"
                    shift 2
                    ;;
                --append-system-prompt-file)
                    system_prompt_file="$2"
                    shift 2
                    ;;
                --continue)
                    codex_resume=true
                    shift
                    ;;
                --disallowedTools)
                    shift
                    while [[ $# -gt 0 && "$1" != --* ]]; do
                        denied+=("$1")
                        shift
                    done
                    ;;
                *)
                    echo "ERROR: Unsupported Codex agentic-solve argument: $1" >&2
                    return 2
                    ;;
            esac
        done
        prepare_codex_home || return 1
        exclude_codex_from_worktree
        ensure_codex || return 1
        load_openai_api_key || return 1
        if [[ -n "${settings_file}" ]]; then
            if [[ ! -r "${settings_file}" ]]; then
                echo "ERROR: Codex settings file is missing: ${settings_file}." >&2
                return 1
            fi
            if ! settings_denied=$(jq -r '.permissions.deny // [] | .[]' "${settings_file}"); then
                echo "ERROR: failed to read Codex settings deny list: ${settings_file}." >&2
                return 1
            fi
            while IFS= read -r spec; do
                [[ -n "${spec}" ]] || continue
                denied+=("${spec}")
            done <<< "${settings_denied}"
        fi
        if [[ ${#denied[@]} -gt 0 ]]; then
            write_codex_disallowed_rules "${denied[@]}" || return 1
        fi
        if [[ -n "${system_prompt_file}" ]]; then
            prompt="$(cat "${system_prompt_file}")"$'\n\n'"${prompt}"
        fi
        if [[ "${codex_resume}" == true ]]; then
            harness_args+=(resume --last)
        fi
        if ! login_codex; then
            return 1
        fi
    else
        harness_args=(
            --permission-mode default
            --allowedTools "${ALLOWED_TOOLS}"
            --verbose
            "$@"
        )
    fi
    local cmd=(
        agentic-ci run
        --backend local
        --harness "${harness}"
        --model "${model}"
        --workdir "${WORKDIR}"
        "${extra_args[@]+"${extra_args[@]}"}"
        "${prompt}"
        --
        "${harness_args[@]+"${harness_args[@]}"}"
    )
    local run_tmp
    run_tmp=$(mktemp -d /tmp/agentic-ci-wrapper.XXXXXX)
    # Login already wrote $CODEX_HOME/auth.json. Drop the key so agentic-ci
    # does not log in again; concurrent logins against one home fail.
    local -a invoke=()
    if [[ "${harness}" == "codex" ]]; then
        invoke=(env -u OPENAI_API_KEY)
    fi
    local rc=0
    if [[ -n "${timeout_seconds}" ]]; then
        TMPDIR="${run_tmp}" timeout "${timeout_seconds}" "${invoke[@]}" "${cmd[@]}" 2>&1 | tee -a "${WORKDIR}/artifacts/claude-output.log" || rc=${PIPESTATUS[0]}
    else
        TMPDIR="${run_tmp}" "${invoke[@]}" "${cmd[@]}" 2>&1 | tee -a "${WORKDIR}/artifacts/claude-output.log" || rc=${PIPESTATUS[0]}
    fi
    find "${run_tmp}" -name 'claude-otel.jsonl' -type f -exec cat {} + >> "${OTEL_LOG}" 2>/dev/null || true
    rm -rf "${run_tmp}"
    return $rc
}

# Token totals come from Codex response.completed events. Dollar amounts come
# from codex.cost.usage when agentic-ci has written that metric. Prints JSON:
#   {"version","session_id","cost_from_metric","models":{model:{input,output,cache_read,cache_create,turns,cost?}}}
codex_otel_usage() {
    local otel_path=$1
    python3 - "${otel_path}" << 'PY'
import json
import math
import sys
from collections import defaultdict

path = sys.argv[1]
models = defaultdict(lambda: {
    "input": 0,
    "output": 0,
    "cache_read": 0,
    "cache_create": 0,
    "turns": 0,
})
version = ""
session_id = ""
cost_from_metric = False


def attribute_value(value):
    if not isinstance(value, dict):
        return None
    for key in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if key in value:
            return value[key]
    return None


def as_int(attrs, key):
    raw = attrs.get(key)
    if raw is None or raw == "":
        return 0
    try:
        return int(float(raw))
    except (TypeError, ValueError):
        return 0


def point_attributes(point):
    attrs = {}
    for attr in point.get("attributes", []):
        key = attr.get("key")
        if key:
            attrs[key] = attribute_value(attr.get("value"))
    return attrs


def point_number(point):
    if "asDouble" in point:
        raw = point["asDouble"]
    elif "asInt" in point:
        raw = point["asInt"]
    else:
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value):
        return None
    return value


with open(path) as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        record_path = record.get("path", "")
        payload = record.get("payload") or {}
        if "/v1/metrics" in record_path:
            for resource in payload.get("resourceMetrics", []):
                for scope in resource.get("scopeMetrics", []):
                    for metric in scope.get("metrics", []):
                        if metric.get("name") != "codex.cost.usage":
                            continue
                        data = metric.get("sum", metric.get("gauge", {}))
                        for point in data.get("dataPoints", []):
                            amount = point_number(point)
                            if amount is None:
                                continue
                            attrs = point_attributes(point)
                            model = str(attrs.get("model") or "unknown")
                            models[model]["cost"] = round(models[model].get("cost", 0) + amount, 6)
                            cost_from_metric = True
            continue
        if "/v1/logs" not in record_path:
            continue
        for resource in payload.get("resourceLogs", []):
            for scope in resource.get("scopeLogs", []):
                for item in scope.get("logRecords", []):
                    attrs = {}
                    for attr in item.get("attributes", []):
                        key = attr.get("key")
                        if key:
                            attrs[key] = attribute_value(attr.get("value"))
                    if not version and attrs.get("app.version"):
                        version = str(attrs["app.version"])
                    if not session_id and attrs.get("conversation.id"):
                        session_id = str(attrs["conversation.id"])
                    event = attrs.get("event.name") or ""
                    model = str(attrs.get("model") or "")
                    if event != "codex.sse_event" or attrs.get("event.kind") != "response.completed":
                        continue
                    if not model:
                        model = "unknown"
                    fresh = max(
                        as_int(attrs, "input_token_count")
                        - as_int(attrs, "cached_token_count")
                        - as_int(attrs, "cache_write_token_count"),
                        0,
                    )
                    models[model]["turns"] += 1
                    models[model]["input"] += fresh
                    models[model]["output"] += as_int(attrs, "output_token_count")
                    models[model]["cache_read"] += as_int(attrs, "cached_token_count")
                    models[model]["cache_create"] += as_int(attrs, "cache_write_token_count")

print(json.dumps({
    "version": version,
    "session_id": session_id,
    "cost_from_metric": cost_from_metric,
    "models": models,
}))
PY
}

finalize_session_metrics() {
    if [[ "${EVAL_MODE:-}" == "true" ]]; then
        return 0
    fi
    # phase is "solve" or "review". Each step writes its own artifact so a
    # later phase cannot overwrite the earlier phase's cost row.
    local phase="${1:-}"
    rm -f "${SHARED_DIR}/claude-otel.jsonl" "${SHARED_DIR}/claude-session-metrics-autodl.json"
    if [[ "${phase}" != "solve" && "${phase}" != "review" ]]; then
        echo "Warning: finalize_session_metrics requires phase solve or review, skipping session metrics"
        return 0
    fi
    if [[ ! -f "${EXTRACT_METRICS}" ]]; then
        echo "Warning: extract_metrics.py not found, skipping session metrics"
        return 0
    fi
    if [[ ! -s "${OTEL_LOG}" ]]; then
        echo "Warning: No OTEL data collected, skipping session metrics"
        return 0
    fi
    local metrics_tmp dest usage
    metrics_tmp=$(mktemp)
    dest="${ARTIFACT_DIR}/claude-session-metrics-${phase}-autodl.json"
    local extract_rc=0
    python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${metrics_tmp}" 2>&1 || extract_rc=$?
    if [[ ! -s "${metrics_tmp}" ]]; then
        echo "Warning: Failed to extract session metrics"
        rm -f "${metrics_tmp}"
        return 0
    fi
    if ! usage=$(codex_otel_usage "${OTEL_LOG}"); then
        echo "Warning: Failed to read Codex usage, keeping extracted session metrics"
        usage=""
    fi
    if [[ -n "${usage}" ]] && jq -e '(.models // {}) | length > 0' <<<"${usage}" >/dev/null 2>&1; then
        local patched
        patched=$(mktemp)
        if jq --argjson usage "${usage}" '
          .rows[0] as $r
          | ($usage.models | to_entries | max_by(.value.input + .value.cache_read + .value.cache_create)) as $top
          | ($top.key) as $model
          | ($usage.models[$model]) as $tokens
          | .rows[0] = ($r + {
              model: (if ($r.model | length) > 0 then $r.model else $model end),
              session_id: (if ($r.session_id | length) > 0 then $r.session_id else $usage.session_id end),
              claude_code_version: (if ($r.claude_code_version | length) > 0 then $r.claude_code_version else $usage.version end),
              num_turns: (if ($r.num_turns | tonumber) > 0 then $r.num_turns else ($tokens.turns | tostring) end),
              input_tokens: (if ($r.input_tokens | tonumber) > 0 then $r.input_tokens else ($tokens.input | tostring) end),
              output_tokens: (if ($r.output_tokens | tonumber) > 0 then $r.output_tokens else ($tokens.output | tostring) end),
              cache_read_input_tokens: (if ($r.cache_read_input_tokens | tonumber) > 0 then $r.cache_read_input_tokens else ($tokens.cache_read | tostring) end),
              cache_creation_input_tokens: (if ($r.cache_creation_input_tokens | tonumber) > 0 then $r.cache_creation_input_tokens else ($tokens.cache_create | tostring) end),
              total_cost_usd: (if $usage.cost_from_metric then (([$usage.models[] | .cost // 0] | add // 0) | tostring) else $r.total_cost_usd end)
            })
        ' "${metrics_tmp}" > "${patched}"; then
            mv "${patched}" "${metrics_tmp}"
        else
            echo "Warning: Failed to apply Codex usage to session metrics"
            rm -f "${patched}"
        fi
    fi
    if [[ "${extract_rc}" -ne 0 ]] && ! jq -e '(.rows[0].input_tokens | tonumber) > 0 or (.rows[0].output_tokens | tonumber) > 0' "${metrics_tmp}" >/dev/null 2>&1; then
        echo "Warning: Failed to extract session metrics"
        rm -f "${metrics_tmp}"
        return 0
    fi
    cp "${metrics_tmp}" "${dest}"
    rm -f "${metrics_tmp}"
    echo "Session metrics autodl written to ${dest}"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/trt-telemetry.sh"
echo "Telemetry helper written to ${SHARED_DIR}/trt-telemetry.sh"

echo "=== TRT Init Model Complete ==="
