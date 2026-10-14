#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Init ==="

# --- Gangway override ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY:-}" ]]; then
    echo "Applying Gangway override: JIRA_ISSUE_KEY=${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
    JIRA_ISSUE_KEY="${MULTISTAGE_PARAM_OVERRIDE_JIRA_ISSUE_KEY}"
fi

[[ -n "${JIRA_ISSUE_KEY:-}" ]] || { echo "ERROR: JIRA_ISSUE_KEY is required."; exit 1; }
[[ -n "${UPSTREAM_REPO:-}" ]] || { echo "ERROR: UPSTREAM_REPO is required."; exit 1; }
[[ -n "${FORK_REPO:-}" ]] || { echo "ERROR: FORK_REPO is required."; exit 1; }

echo "Issue: ${JIRA_ISSUE_KEY} | Upstream: ${UPSTREAM_REPO} | Fork: ${FORK_REPO}"

# --- Validate GitHub tokens from github-app-auth step ---
for f in gh-fork-token gh-upstream-token github-app-auth.sh github-app-token-outputs; do
    [[ -f "${SHARED_DIR}/${f}" ]] || { echo "ERROR: ${f} not found in SHARED_DIR. Run trt-github-app-auth step first."; exit 1; }
done
echo "GitHub tokens validated."

# --- Persist issue key ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"

# --- Fetch Jira issue ---
echo "Fetching issue details from Jira..."
curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
    "https://redhat.atlassian.net/rest/api/2/issue/${JIRA_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority" \
    > "${SHARED_DIR}/jira-issue.json" || {
    echo "ERROR: Failed to fetch issue ${JIRA_ISSUE_KEY} from Jira."; exit 1;
}

echo "Summary: $(jq -r '.fields.summary // "No summary"' "${SHARED_DIR}/jira-issue.json")"

# --- Agent library for downstream test steps ---
cat > "${SHARED_DIR}/trt-agent.sh" << 'TRT_AGENT_EOF'
#!/bin/bash
# TRT agent library: model resolution, pinned OpenCode install, security
# profiles, and the runner used by jira-solver / review-responder workers.
# Embedded byte-identically in the three init steps — keep them in sync.
#
# Model selection: MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL > AGENT_MODEL >
# legacy CLAUDE_MODEL. Unknown models or missing credentials fall back to
# TRT_DEFAULT_MODEL with a logged warning; the choice is recorded in
# ${ARTIFACT_DIR}/agent-model.json.

TRT_OPENCODE_VERSION="2.0.26"
TRT_OPENCODE_URL="https://opencode.ai/files/bin/2.0.26/opencode-linux-x64-baseline.tar.gz"
TRT_OPENCODE_SHA256="0e682946fea509299f1515dfb6261aa5cf8d1d2e5ccdc833470523acb7222106"
TRT_OPENCODE_ROOT="/tmp/trt-opencode"
TRT_DEFAULT_MODEL="google-vertex-anthropic/claude-opus-4-6@default"

if [[ -n "${SHARED_DIR:-}" ]] && [[ -f "${SHARED_DIR}/github-app-auth.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/github-app-auth.sh"
fi

trt_load_provider_keys() {
    if [[ -z "${OPENAI_API_KEY:-}" ]] && [[ -r "${OPENAI_API_KEY_PATH:-}" ]]; then
        export OPENAI_API_KEY="$(<"${OPENAI_API_KEY_PATH}")"
    fi
    # OpenCode's built-in zai provider reads ZHIPU_API_KEY.
    if [[ -z "${ZHIPU_API_KEY:-}" && -z "${ZAI_API_KEY:-}" ]] && [[ -r "${ZAI_API_KEY_PATH:-}" ]]; then
        export ZAI_API_KEY="$(<"${ZAI_API_KEY_PATH}")"
    fi
    if [[ -z "${ZHIPU_API_KEY:-}" ]] && [[ -n "${ZAI_API_KEY:-}" ]]; then
        export ZHIPU_API_KEY="${ZAI_API_KEY}"
    fi
}

trt_resolve_model() {
    local requested="${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-${AGENT_MODEL:-${CLAUDE_MODEL:-}}}"
    TRT_MODEL_REQUESTED="${requested}"
    TRT_MODEL_FALLBACK_REASON=""

    local candidate=""
    case "${requested}" in
        ""|default|claude) candidate="${TRT_DEFAULT_MODEL}" ;;
        claude-*) candidate="google-vertex-anthropic/${requested}@default" ;;
        glm|glm-*) candidate="zai/glm-4.6" ;;
        sol|gpt-6.1-sol) candidate="openai/gpt-6.1-sol" ;;
        luna|gpt-6-luna) candidate="openai/gpt-6-luna" ;;
        zai/*|openai/*|google-vertex*/*) candidate="${requested}" ;;
        *) TRT_MODEL_FALLBACK_REASON="unknown model '${requested}'" ;;
    esac

    if [[ -n "${candidate}" ]]; then
        case "${candidate}" in
            google-vertex*)
                [[ -r "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] || \
                    TRT_MODEL_FALLBACK_REASON="Vertex credentials unavailable for ${candidate}" ;;
            openai/*)
                trt_load_provider_keys
                [[ -n "${OPENAI_API_KEY:-}" ]] || TRT_MODEL_FALLBACK_REASON="OPENAI_API_KEY unavailable for ${candidate}" ;;
            zai/*)
                trt_load_provider_keys
                [[ -n "${ZAI_API_KEY:-}" ]] || TRT_MODEL_FALLBACK_REASON="ZAI_API_KEY unavailable for ${candidate}" ;;
        esac
    fi

    if [[ -n "${TRT_MODEL_FALLBACK_REASON}" ]]; then
        echo "WARNING: agent model falling back to ${TRT_DEFAULT_MODEL}: ${TRT_MODEL_FALLBACK_REASON}" >&2
        TRT_MODEL="${TRT_DEFAULT_MODEL}"
    else
        TRT_MODEL="${candidate}"
    fi
    export AGENT_MODEL="${TRT_MODEL}"

    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        jq -n \
            --arg requested "${TRT_MODEL_REQUESTED}" \
            --arg effective "${TRT_MODEL}" \
            --arg fallback_reason "${TRT_MODEL_FALLBACK_REASON}" \
            '{requested_model: $requested, effective_model: $effective, model_fallback_reason: $fallback_reason}' \
            > "${ARTIFACT_DIR}/agent-model.json"
    fi
}

trt_write_opencode_shim() {
    local shim_path="$1"
    mkdir -p "$(dirname "${shim_path}")"
    # agentic-ci 0.3.48 passes --dangerously-skip-permissions, removed in
    # OpenCode V2 (--auto is the equivalent). --standalone gives each run a
    # private server so OPENCODE_CONFIG_DIR is re-read and parallel eval
    # cases do not share state.
    cat > "${shim_path}" << 'TRT_SHIM_EOF'
#!/usr/bin/env bash
set -euo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-real"

if [[ "${1:-}" != "run" ]]; then
    exec "${REAL}" "$@"
fi
shift

args=(run --standalone)
for a in "$@"; do
    if [[ "${a}" == "--dangerously-skip-permissions" ]]; then
        args+=(--auto)
    else
        args+=("${a}")
    fi
done
exec "${REAL}" "${args[@]}"
TRT_SHIM_EOF
    chmod +x "${shim_path}"
}

trt_opencode_setup() {
    if [[ -x "${TRT_OPENCODE_ROOT}/bin/opencode" ]]; then
        export PATH="${TRT_OPENCODE_ROOT}/bin:${PATH}"
        return 0
    fi
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    if [[ "${os}" != "Linux" || "${arch}" != "x86_64" ]]; then
        echo "ERROR: pinned OpenCode install supports linux/x86_64 only (got ${os}/${arch})" >&2
        return 1
    fi

    mkdir -p "${TRT_OPENCODE_ROOT}/bin" "${TRT_OPENCODE_ROOT}/download"
    local archive="${TRT_OPENCODE_ROOT}/download/opencode.tar.gz"
    echo "Downloading OpenCode v${TRT_OPENCODE_VERSION}..."
    curl -fsSL --retry 3 --retry-delay 5 -o "${archive}" "${TRT_OPENCODE_URL}" || {
        echo "ERROR: failed to download OpenCode" >&2
        return 1
    }
    local sha_actual
    if command -v sha256sum >/dev/null 2>&1; then
        sha_actual="$(sha256sum "${archive}" | awk '{print $1}')"
    else
        sha_actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
    fi
    if [[ "${sha_actual}" != "${TRT_OPENCODE_SHA256}" ]]; then
        echo "ERROR: OpenCode sha256 mismatch: expected ${TRT_OPENCODE_SHA256}, got ${sha_actual}" >&2
        return 1
    fi
    tar -xzf "${archive}" -C "${TRT_OPENCODE_ROOT}/download"
    mv "${TRT_OPENCODE_ROOT}/download/opencode" "${TRT_OPENCODE_ROOT}/bin/opencode-real"
    chmod +x "${TRT_OPENCODE_ROOT}/bin/opencode-real"
    trt_write_opencode_shim "${TRT_OPENCODE_ROOT}/bin/opencode"
    export PATH="${TRT_OPENCODE_ROOT}/bin:${PATH}"
}

trt_agent_profile() {
    # Generate the CI-owned OpenCode config for a profile under
    # TRT_OPENCODE_ROOT/config/<profile>. The permission rules deny the
    # direct command forms; the plugin is the security backbone — it runs
    # in-process from this CI-owned directory and cannot be weakened by
    # repository-shipped OpenCode config (which CAN override the
    # opencode.json permission rules).
    local profile="$1"
    case "${profile}" in
        solver|reviewer) ;;
        *) echo "ERROR: unknown agent profile '${profile}' (solver|reviewer)" >&2; return 2 ;;
    esac

    local dir="${TRT_OPENCODE_ROOT}/config/${profile}"
    mkdir -p "${dir}/plugin"

    local permissions message checks
    if [[ "${profile}" == "solver" ]]; then
        # Parity with the former Claude Code block-gh hook: the pipeline
        # creates the PR, so the agent must not use gh.
        permissions='{"bash": {"gh": "deny", "gh *": "deny"}}'
        message="CI security policy: do not use the gh CLI. Push your branch with git and write the PR description to the artifacts directory; the pipeline creates the PR after you exit."
        checks='const SHELL_CHECKS: RegExp[] = [/\bgh\b/]
const READ_CHECKS: RegExp[] = []
// Command substitution can hide the real command from inspection.
const UNSAFE: RegExp | undefined = /\$\(|\x60|<\(|>\(|\$\{|\$\x27/'
    else
        # Parity with the former reviewer --disallowedTools globs: the
        # pipeline pushes; the agent must not push, dump credentials, or
        # read secret files. Bash patterns match any command mentioning a
        # secret path (covers cat/head/sed/od and friends).
        permissions='{
            "bash": {
                "git push": "deny", "git push *": "deny",
                "git remote -v": "deny", "git remote -v *": "deny",
                "git config*credential*": "deny",
                "git config*--list*": "deny",
                "git config*-l*": "deny",
                "echo*GITHUB_TOKEN*": "deny",
                "echo*GH_FORK_TOKEN*": "deny",
                "env": "deny", "env *": "deny",
                "printenv": "deny", "printenv *": "deny",
                "*claude-code-service-account*": "deny",
                "*gh-fork-token*": "deny",
                "*gh-upstream-token*": "deny",
                "*github-app-auth.sh*": "deny",
                "*google-token*": "deny",
                "*/var/run/github-token*": "deny"
            },
            "read": {
                "*claude-code-service-account*": "deny",
                "*gh-fork-token*": "deny",
                "*gh-upstream-token*": "deny",
                "*github-app-auth.sh*": "deny",
                "*google-token*": "deny",
                "*/var/run/github-token*": "deny"
            }
        }'
        message="CI security policy: this command is blocked (credential access or push protection). Do not read credentials or push; the pipeline handles pushes."
        checks='const SHELL_CHECKS: RegExp[] = [
  /\bgit\s+push\b/,
  /\bgit\s+remote\s+(-v|--verbose)\b/,
  /\bgit\s+config\b.*(\s-l\b|\s--list\b|credential)/,
  /(^|&&|\|\||;|\||\n)\s*(env|printenv)(\s|$)/,
  /GITHUB_TOKEN|GH_FORK_TOKEN|GH_UPSTREAM_TOKEN/,
  /gh-fork-token|gh-upstream-token|google-token|github-app-auth\.sh|claude-code-service-account|github-token/,
]
const READ_CHECKS: RegExp[] = [
  /gh-fork-token|gh-upstream-token|google-token|github-app-auth\.sh|claude-code-service-account|github-token/,
]
const UNSAFE: RegExp | undefined = undefined'
    fi

    local model="${TRT_MODEL:-${TRT_DEFAULT_MODEL}}"
    jq -n \
        --arg model "${model}" \
        --arg plugin "${dir}/plugin" \
        --argjson permissions "${permissions}" \
        '{
            "$schema": "https://opencode.ai/config.json",
            "model": $model,
            "permission": $permissions,
            "plugins": [$plugin]
        }' > "${dir}/opencode.json"

    cat > "${dir}/plugin/index.ts" << TRT_PLUGIN_EOF
import { Plugin } from "@opencode/plugin"

// TRT CI guard (${profile} profile). The pipeline owns PR creation and
// pushing; see the checks below for what the agent must not do.

const DENY_MESSAGE =
  "${message}"

// Shell checks run against the command with quotes/backslashes stripped so
// g"h" or g\h cannot sneak past a word match. env/printenv must start a
// command segment, so "go env" stays allowed.
${checks}

function flat(s: string): string {
  return s.replace(/['"\x5c]/g, "")
}

export default Plugin.define({
  id: "trt-ci-guard",
  setup(ctx) {
    void ctx.permission.hook("evaluate", async (event) => {
      if (event.effect === "deny") return
      for (const resource of event.resources ?? []) {
        if (event.action === "shell") {
          if (UNSAFE && UNSAFE.test(resource)) {
            event.effect = "deny"
            event.message = DENY_MESSAGE
            return
          }
          const command = flat(resource)
          for (const check of SHELL_CHECKS) {
            if (check.test(command)) {
              event.effect = "deny"
              event.message = DENY_MESSAGE
              return
            }
          }
        } else if (event.action === "read") {
          for (const check of READ_CHECKS) {
            if (check.test(resource)) {
              event.effect = "deny"
              event.message = DENY_MESSAGE
              return
            }
          }
        }
      }
    })
  },
})
TRT_PLUGIN_EOF
}

trt_agent_run() {
    # usage: trt_agent_run --profile solver|reviewer --timeout SECONDS
    #                       [--system-prompt-file FILE] [--continue]
    #                       PROMPT [extra opencode run args...]
    # Output is teed to ${WORKDIR}/artifacts/agent-output.log.
    local profile="solver" timeout_seconds="" system_prompt_file=""
    local passthrough=()
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --profile) profile="$2"; shift 2 ;;
            --timeout) timeout_seconds="$2"; shift 2 ;;
            --system-prompt-file) system_prompt_file="$2"; shift 2 ;;
            --continue) passthrough+=(--continue); shift ;;
            *) echo "ERROR: unknown trt_agent_run option: $1" >&2; return 2 ;;
        esac
    done
    local prompt="${1:-}"
    [[ -n "${prompt}" ]] || { echo "ERROR: trt_agent_run requires a prompt" >&2; return 2; }
    [[ -n "${timeout_seconds}" ]] || { echo "ERROR: --timeout is required" >&2; return 2; }
    shift || true
    passthrough+=("$@")

    trt_resolve_model
    trt_opencode_setup
    trt_agent_profile "${profile}"
    trt_load_provider_keys
    export OPENCODE_CONFIG_DIR="${TRT_OPENCODE_ROOT}/config/${profile}"

    # OpenCode's vertex provider reads GOOGLE_VERTEX_PROJECT/LOCATION (some
    # builds GOOGLE_CLOUD_PROJECT/VERTEX_LOCATION); CI mounts Claude Code's
    # ANTHROPIC_VERTEX_PROJECT_ID/CLOUD_ML_REGION. Map both spellings.
    export GOOGLE_VERTEX_PROJECT="${GOOGLE_VERTEX_PROJECT:-${ANTHROPIC_VERTEX_PROJECT_ID:-}}"
    export GOOGLE_VERTEX_LOCATION="${GOOGLE_VERTEX_LOCATION:-${CLOUD_ML_REGION:-global}}"
    export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-${GOOGLE_VERTEX_PROJECT}}"
    export VERTEX_LOCATION="${VERTEX_LOCATION:-${GOOGLE_VERTEX_LOCATION}}"

    if [[ -n "${system_prompt_file}" ]]; then
        prompt="$(cat "${system_prompt_file}")

---

${prompt}"
    fi

    # Installation tokens last 1h; mint a fresh one before each long child.
    if declare -F refresh_github_tokens >/dev/null 2>&1; then
        refresh_github_tokens || echo "WARNING: GitHub App token refresh failed; continuing with existing tokens"
    fi

    local workdir="${WORKDIR:?WORKDIR must be set before calling trt_agent_run}"
    mkdir -p "${workdir}/artifacts"
    echo "trt_agent_run: profile=${profile} model=${TRT_MODEL} requested='${TRT_MODEL_REQUESTED}' timeout=${timeout_seconds}"

    local rc=0
    timeout "${timeout_seconds}" agentic-ci run \
        --backend local \
        --harness opencode \
        --model "${TRT_MODEL}" \
        --workdir "${workdir}" \
        "${prompt}" \
        -- \
        ${passthrough[@]+"${passthrough[@]}"} 2>&1 | tee -a "${workdir}/artifacts/agent-output.log" || rc=${PIPESTATUS[0]}
    return "${rc}"
}
TRT_AGENT_EOF
chmod +x "${SHARED_DIR}/trt-agent.sh"
echo "Agent library written to ${SHARED_DIR}/trt-agent.sh"

echo "=== TRT Init Complete ==="
