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
SESSION_PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/trt-session-initial-prompt.XXXXXX")
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
    if [[ -n "${CODEX_HOME_CLEANUP_INSTALLED:-}" && -n "${CODEX_HOME:-}" && -d "${CODEX_HOME}" ]]; then
        return 0
    fi
    CODEX_HOME=$(mktemp -d /tmp/codex-home.XXXXXX) || return 1
    export CODEX_HOME
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

configure_codex_project_plugins() {
    local settings="${WORKDIR}/.claude/settings.json"
    local github_enabled=false
    unset CLAUDE_PLUGIN_ROOT
    if [[ -e "${settings}" || -L "${settings}" ]]; then
        if [[ ! -r "${settings}" ]]; then
            echo "ERROR: project plugin settings are unreadable: ${settings}" >&2
            return 1
        fi
        if ! github_enabled=$(jq -er '
          if type != "object" then error("settings must be an object")
          elif (has("enabledPlugins") | not) then false
          elif (.enabledPlugins | type) != "object" then error("enabledPlugins must be an object")
          elif (.enabledPlugins | has("github@ai-helpers") | not) then false
          elif (.enabledPlugins["github@ai-helpers"] | type) != "boolean" then error("plugin state must be boolean")
          else .enabledPlugins["github@ai-helpers"]
          end
          | tostring
        ' "${settings}"); then
            echo "ERROR: invalid project plugin settings: ${settings}" >&2
            return 1
        fi
    fi

    if [[ "${github_enabled}" == true ]]; then
        if ! codex plugin marketplace add /opt/ai-helpers >/dev/null 2>&1; then
            echo "ERROR: failed to add the ai-helpers Codex plugin marketplace" >&2
            return 1
        fi
        local plugin_json plugin_root cache_root script
        if ! plugin_json=$(codex plugin add github@ai-helpers --json 2>/dev/null); then
            echo "ERROR: failed to install the github@ai-helpers Codex plugin" >&2
            return 1
        fi
        if ! plugin_root=$(jq -er '
          select(.pluginId == "github@ai-helpers")
          | .installedPath
          | select(type == "string" and length > 0)
        ' <<<"${plugin_json}"); then
            echo "ERROR: Codex did not report the installed github@ai-helpers plugin path" >&2
            return 1
        fi
        if ! plugin_root=$(realpath -e -- "${plugin_root}") \
            || ! cache_root=$(realpath -e -- "${CODEX_HOME}/plugins/cache"); then
            echo "ERROR: Codex reported an invalid github@ai-helpers plugin path" >&2
            return 1
        fi
        case "${plugin_root}" in
            "${cache_root}"/*) ;;
            *)
                echo "ERROR: Codex installed github@ai-helpers outside its native plugin cache" >&2
                return 1
                ;;
        esac
        script="${plugin_root}/skills/upload-screenshot/upload_screenshot.sh"
        if [[ ! -f "${script}" || ! -x "${script}" ]]; then
            echo "ERROR: installed github@ai-helpers is missing the upload-screenshot helper" >&2
            return 1
        fi
        # Codex shell tools inherit this process environment. The compatibility
        # variable is required by the existing Claude-authored skill command.
        export CLAUDE_PLUGIN_ROOT="${plugin_root}"
    elif ! codex plugin remove github@ai-helpers >/dev/null 2>&1; then
        echo "ERROR: failed to disable the github@ai-helpers Codex plugin" >&2
        return 1
    fi
}

codex_project_mcp_is_allowed() {
    local server=$1
    [[ " ${ALLOWED_TOOLS:-} " == *" mcp__${server}__"* ]]
}

codex_project_mcp_url_is_safe() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    url = urlsplit(sys.argv[1])
except ValueError:
    sys.exit(1)
if url.scheme not in {"http", "https"} or not url.hostname:
    sys.exit(1)
if url.username is not None or url.password is not None or url.query or url.fragment:
    sys.exit(1)
PY
}

# Codex does not consume the Claude-compatible project .mcp.json directly.
# Register only servers already allowed by the job's ALLOWED_TOOLS contract;
# this keeps unrelated or interactive project servers disabled.
codex_project_mcp_server_type() {
    local config=$1 server=$2
    jq -r --arg server "${server}" \
        '.mcpServers[$server].type // (if .mcpServers[$server].url then "http" else "stdio" end)' \
        "${config}"
}

codex_project_mcp_validate_server() {
    local config=$1 server=$2 type url
    type=$(codex_project_mcp_server_type "${config}" "${server}") || {
        echo "ERROR: failed to read MCP server ${server}" >&2
        return 1
    }
    case "${type}" in
        stdio)
            if ! jq -e --arg server "${server}" '
              (.mcpServers[$server].command // null) as $command
              | (.mcpServers[$server].args // []) as $args
              | (.mcpServers[$server].env // {}) as $env
              | ($command | type == "string" and length > 0 and index("\u0000") == null)
                and ($args | type == "array"
                  and all(.[]; type == "string" and index("\u0000") == null))
                and ($env | type == "object"
                  and all(to_entries[];
                    (.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
                    and (.value | type == "string" and index("\u0000") == null)))
            ' "${config}" >/dev/null; then
                echo "ERROR: invalid stdio configuration for MCP server ${server}" >&2
                return 1
            fi
            ;;
        http)
            if ! jq -e --arg server "${server}" \
                '.mcpServers[$server].url | type == "string"' "${config}" >/dev/null; then
                echo "ERROR: invalid HTTP configuration for MCP server ${server}" >&2
                return 1
            fi
            url=$(jq -r --arg server "${server}" '.mcpServers[$server].url' "${config}") || return 1
            if [[ -z "${url}" ]] || ! codex_project_mcp_url_is_safe "${url}"; then
                echo "ERROR: invalid or credential-bearing URL for MCP server ${server}" >&2
                return 1
            fi
            ;;
        *)
            echo "ERROR: unsupported transport for MCP server ${server}" >&2
            return 1
            ;;
    esac
}

codex_project_mcp_collect_servers() {
    local config=$1 output_name=$2 server names rc=0
    local -n output=${output_name}
    output=()
    names=$(mktemp "${CODEX_HOME}/.trt-project-mcp-names.XXXXXX") || return 1
    if [[ -f "${config}" ]] && ! python3 - "${config}" > "${names}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    servers = json.load(handle)["mcpServers"]
for name in sorted(servers):
    sys.stdout.buffer.write(name.encode() + b"\0")
PY
    then
        rm -f "${names}"
        echo "ERROR: failed to read project MCP server names" >&2
        return 1
    fi
    while IFS= read -r -d '' server; do
        if [[ ! "${server}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "ERROR: unsafe MCP server name in ${config}" >&2
            rc=1
            continue
        fi
        codex_project_mcp_is_allowed "${server}" || continue
        if codex_project_mcp_validate_server "${config}" "${server}"; then
            output+=("${server}")
        else
            rc=1
        fi
    done < "${names}"
    rm -f "${names}"
    return "${rc}"
}

codex_project_mcp_remove_servers() {
    local action=$1 server rc=0
    shift
    for server in "$@"; do
        if ! codex mcp remove "${server}" </dev/null >/dev/null 2>&1; then
            echo "ERROR: failed to ${action} MCP server ${server}" >&2
            rc=1
        fi
    done
    return "${rc}"
}

codex_project_mcp_remove_managed() {
    local state=$1
    [[ -f "${state}" ]] || return 0
    if ! jq -e '
      .servers | type == "array"
        and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"))
    ' "${state}" >/dev/null 2>&1; then
        echo "ERROR: invalid managed MCP state" >&2
        return 1
    fi
    local -a previous=()
    mapfile -t previous < <(jq -r '.servers[]' "${state}")
    codex_project_mcp_remove_servers "remove managed" "${previous[@]}"
}

codex_project_mcp_parse_stdio() {
    local config=$1 server=$2 command_name=$3 args_name=$4 env_name=$5
    local -n command_output=${command_name}
    local -n args_output=${args_name}
    local -n env_output=${env_name}
    local parsed kind key value complete=false rc=0
    command_output=""
    args_output=()
    env_output=()
    parsed=$(mktemp "${CODEX_HOME}/.trt-project-mcp-server.XXXXXX") || return 1
    if ! python3 - "${config}" "${server}" > "${parsed}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    server = json.load(handle)["mcpServers"][sys.argv[2]]

def emit(kind, key, value):
    for field in (kind, key, value):
        sys.stdout.buffer.write(field.encode() + b"\0")

emit("command", "", server["command"])
for value in server.get("args", []):
    emit("arg", "", value)
for key, value in server.get("env", {}).items():
    emit("env", key, value)
emit("done", "", "")
PY
    then
        rm -f "${parsed}"
        echo "ERROR: failed to parse stdio MCP server ${server}" >&2
        return 1
    fi
    while IFS= read -r -d '' kind \
        && IFS= read -r -d '' key \
        && IFS= read -r -d '' value; do
        case "${kind}" in
            command) command_output=${value} ;;
            arg) args_output+=("${value}") ;;
            env) env_output+=(--env "${key}=${value}") ;;
            done) complete=true; break ;;
            *) rc=1 ;;
        esac
    done < "${parsed}"
    rm -f "${parsed}"
    if [[ "${complete}" != true || "${rc}" -ne 0 ]]; then
        echo "ERROR: invalid parsed data for stdio MCP server ${server}" >&2
        return 1
    fi
}

codex_project_mcp_register_stdio() {
    local config=$1 server=$2 command
    local -a args=() env_args=()
    codex_project_mcp_parse_stdio "${config}" "${server}" command args env_args || return 1
    if ! codex mcp add "${server}" "${env_args[@]}" -- "${command}" "${args[@]}" \
        >/dev/null 2>&1; then
        echo "ERROR: failed to register stdio MCP server ${server}" >&2
        return 1
    fi
}

codex_project_mcp_register_http() {
    local config=$1 server=$2 url
    url=$(jq -r --arg server "${server}" '.mcpServers[$server].url' "${config}") || return 1
    if ! timeout --kill-after=5s 60s codex mcp add "${server}" --url "${url}" \
        </dev/null >/dev/null 2>&1; then
        echo "ERROR: failed to register HTTP MCP server ${server}" >&2
        return 1
    fi
}

codex_project_mcp_register_server() {
    local config=$1 server=$2 type
    type=$(codex_project_mcp_server_type "${config}" "${server}") || return 1
    case "${type}" in
        stdio) codex_project_mcp_register_stdio "${config}" "${server}" ;;
        http) codex_project_mcp_register_http "${config}" "${server}" ;;
        *)
            echo "ERROR: unsupported transport for MCP server ${server}" >&2
            return 1
            ;;
    esac
}

codex_project_mcp_register_servers() {
    local config=$1 server rc=0
    shift
    local -a servers=("$@")
    for server in "${servers[@]}"; do
        codex_project_mcp_register_server "${config}" "${server}" || rc=1
    done
    if [[ "${rc}" -ne 0 ]]; then
        codex_project_mcp_remove_servers "clean up" "${servers[@]}" || true
        return 1
    fi
}

codex_project_mcp_persist_state() {
    local state=$1 fingerprint=$2
    shift 2
    local servers_json='[]' state_tmp
    local -a servers=("$@")
    if [[ ${#servers[@]} -gt 0 ]]; then
        servers_json=$(printf '%s\n' "${servers[@]}" | jq -R . | jq -s .) || return 1
    fi
    state_tmp=$(mktemp "${CODEX_HOME}/.trt-project-mcp-state.XXXXXX") || return 1
    if ! jq -n --arg fingerprint "${fingerprint}" --argjson servers "${servers_json}" \
        '{fingerprint: $fingerprint, servers: $servers}' > "${state_tmp}"; then
        rm -f "${state_tmp}"
        return 1
    fi
    mv "${state_tmp}" "${state}"
}

_configure_codex_project_mcp() {
    local config="${WORKDIR}/.mcp.json"
    local state="${CODEX_HOME}/.trt-project-mcp-state.json"
    local config_hash="absent" fingerprint
    local -a servers=()
    if [[ -f "${config}" ]]; then
        config_hash=$(sha256sum "${config}" | cut -d' ' -f1) || return 1
    fi
    fingerprint=$(printf '%s\0%s' "${config_hash}" "${ALLOWED_TOOLS:-}" | sha256sum | cut -d' ' -f1) || return 1
    if [[ -f "${state}" ]] && jq -e --arg fingerprint "${fingerprint}" '
      .fingerprint == $fingerprint
        and (.servers | type == "array")
        and all(.servers[]; type == "string" and test("^[A-Za-z0-9._-]+$"))
    ' "${state}" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f "${config}" ]] && ! jq -e '.mcpServers | type == "object"' "${config}" >/dev/null 2>&1; then
        echo "ERROR: invalid project MCP configuration: ${config}" >&2
        return 1
    fi
    codex_project_mcp_collect_servers "${config}" servers || return 1
    # Do not register anything while a stale managed server may remain.
    codex_project_mcp_remove_managed "${state}" || return 1
    codex_project_mcp_register_servers "${config}" "${servers[@]}" || return 1
    if ! codex_project_mcp_persist_state "${state}" "${fingerprint}" "${servers[@]}"; then
        echo "ERROR: failed to persist managed MCP state" >&2
        codex_project_mcp_remove_servers "clean up" "${servers[@]}" || true
        return 1
    fi
}

configure_codex_project_mcp() {
    local restore_xtrace=false rc=0
    if [[ $- == *x* ]]; then
        restore_xtrace=true
        set +x
    fi
    _configure_codex_project_mcp || rc=$?
    if ${restore_xtrace}; then
        set -x
    fi
    return "${rc}"
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
    # Codex may redact prompt text in OTEL. Preserve the initial harness prompt
    # privately for extraction; resumed/nudge prompts must not replace it.
    if [[ "${EVAL_MODE:-}" != "true" && ! -s "${SESSION_PROMPT_FILE}" ]]; then
        (umask 077 && printf '%s' "${prompt}" > "${SESSION_PROMPT_FILE}")
    fi
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
        configure_codex_project_plugins || return 1
        configure_codex_project_mcp || return 1
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
# from agentic_ci.codex.cost.usage when agentic-ci has written that metric. Prints JSON:
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
cumulative_costs = {}


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
                        if metric.get("name") not in (
                                "agentic_ci.codex.cost.usage", "codex.cost.usage"):
                            continue
                        data = metric.get("sum", metric.get("gauge", {}))
                        for point in data.get("dataPoints", []):
                            amount = point_number(point)
                            if amount is None:
                                continue
                            attrs = point_attributes(point)
                            model = str(attrs.get("model") or "unknown")
                            if ("sum" in metric
                                    and data.get("aggregationTemporality") == 2):
                                key = (model, str(point.get("startTimeUnixNano", "")))
                                try:
                                    timestamp = int(point.get("timeUnixNano", 0) or 0)
                                except (TypeError, ValueError):
                                    timestamp = 0
                                previous = cumulative_costs.get(key)
                                if previous is None or timestamp >= previous[0]:
                                    cumulative_costs[key] = (timestamp, amount)
                            else:
                                models[model]["cost"] = round(
                                    models[model].get("cost", 0) + amount, 6)
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

for (model, _start), (_timestamp, amount) in cumulative_costs.items():
    models[model]["cost"] = round(models[model].get("cost", 0) + amount, 6)

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
        rm -f "${SESSION_PROMPT_FILE}"
        return 0
    fi
    # phase is "solve" or "review". Each step writes its own artifact so a
    # later phase cannot overwrite the earlier phase's cost row.
    local phase="${1:-}"
    rm -f "${SHARED_DIR}/claude-otel.jsonl" "${SHARED_DIR}/claude-session-metrics-autodl.json"
    if [[ "${phase}" != "solve" && "${phase}" != "review" ]]; then
        echo "Warning: finalize_session_metrics requires phase solve or review, skipping session metrics"
        rm -f "${SESSION_PROMPT_FILE}"
        return 0
    fi
    if [[ ! -f "${EXTRACT_METRICS}" ]]; then
        echo "Warning: extract_metrics.py not found, skipping session metrics"
        rm -f "${SESSION_PROMPT_FILE}"
        return 0
    fi
    if [[ ! -s "${OTEL_LOG}" ]]; then
        echo "Warning: No OTEL data collected, skipping session metrics"
        rm -f "${SESSION_PROMPT_FILE}"
        return 0
    fi
    local metrics_tmp dest metadata_file session_id
    metrics_tmp=$(mktemp)
    dest="${ARTIFACT_DIR}/claude-session-metrics-${phase}-autodl.json"
    local extract_rc=0
    python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${metrics_tmp}" \
        --prompt-file "${SESSION_PROMPT_FILE}" 2>&1 || extract_rc=$?
    if [[ "${extract_rc}" -ne 0 || ! -s "${metrics_tmp}" ]]; then
        echo "Warning: Failed to extract session metrics"
        rm -f "${metrics_tmp}" "${SESSION_PROMPT_FILE}"
        return 0
    fi
    # Carry the real session identity into the domain row used by dashboards.
    # An atomic rewrite avoids leaving malformed metadata if jq fails.
    metadata_file="${SHARED_DIR}/metrics-metadata-${phase}.json"
    session_id=$(jq -r '.rows[0].session_id // ""' "${metrics_tmp}")
    if [[ -n "${session_id}" && -f "${metadata_file}" ]]; then
        local metadata_tmp
        metadata_tmp=$(mktemp)
        if jq --arg session_id "${session_id}" '.session_id = $session_id' \
            "${metadata_file}" > "${metadata_tmp}"; then
            mv "${metadata_tmp}" "${metadata_file}"
        else
            rm -f "${metadata_tmp}"
            echo "Warning: Failed to propagate session identity to metrics metadata"
        fi
    fi
    cp "${metrics_tmp}" "${dest}"
    rm -f "${metrics_tmp}" "${SESSION_PROMPT_FILE}"
    echo "Session metrics autodl written to ${dest}"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/trt-telemetry.sh"
echo "Telemetry helper written to ${SHARED_DIR}/trt-telemetry.sh"

echo "=== TRT Init Model Complete ==="
