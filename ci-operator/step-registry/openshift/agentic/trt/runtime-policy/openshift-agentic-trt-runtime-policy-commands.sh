#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Refs receive only their commands script. Deliver one policy implementation to
# all solver/responder consumers through SHARED_DIR, including eval wrappers.
cat > "${SHARED_DIR}/trt-runtime-policy.sh" <<'RUNTIME_POLICY_EOF'
#!/bin/bash

setup_agent_runtime_policy() {
    AGENT_POLICY_MODE="$1"
    case "${AGENT_POLICY_MODE}" in
        solver|review) ;;
        *) echo "ERROR: unknown agent runtime policy: ${AGENT_POLICY_MODE}" >&2; return 1 ;;
    esac
    HOOKS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ci-agent.XXXXXX")
    if [[ "${AGENT_POLICY_MODE}" == review ]]; then
        touch "${HOOKS_DIR}/allow-gh"
    fi
    cat > "${HOOKS_DIR}/guard-command.sh" <<'HOOK_EOF'
#!/bin/bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "command guard requires jq" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "command guard requires python3" >&2
    exit 2
fi

cmd=$(jq -r '.tool_input.command // ""') || exit 2

result=$(HOOK_BASH_CMD="$cmd" python3 "$(dirname "${BASH_SOURCE[0]}")/command-guard.py") || exit 2

if [[ "${result}" == deny ]]; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
      permissionDecisionReason: "CI mode: no delegation or agent pushes; only the pipeline publishes. gh is disabled in solver mode. Unsupported command forms are denied; quoted commits and inline Node code are allowed."}}' || exit 2
fi
HOOK_EOF
    chmod +x "${HOOKS_DIR}/guard-command.sh"
    cat > "${HOOKS_DIR}/command-guard.py" <<'GUARD_PY'
import os, re, shlex, sys

cmd = os.environ.get("HOOK_BASH_CMD", "")
ALLOW_GH = os.path.isfile(os.path.join(os.path.dirname(__file__), "allow-gh"))
WRAPPERS = {"command", "env", "nice", "nohup", "time", "timeout"}
SHELLS = {"bash", "sh", "dash", "zsh", "ksh"}
EXPANDED_LITERAL = "__CI_LITERAL_HEREDOC__"
# Claude commonly uses this literal-only form for multiline commit messages.
# Unquoted delimiters, substitutions in the body, and other shell substitutions
# are NOT evaluated by this guard. The shell treats a quoted heredoc as data.
LITERAL_HEREDOC = re.compile(
    r"\$\(cat <<(?P<strip_tabs>-)?[ \t]*(?P<quote>['\"])(?P<delimiter>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)\n"
    r"(?P<body>.*?)\n(?(strip_tabs)\t*)(?P=delimiter)\n\)", re.S)
HEREDOC_REDIRECT = re.compile(r"<<(-?)[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2(?=[ \t\n;&|]|$)")


def commands(text):
    """Split shell operators only outside quotes; retain argument boundaries.

    This is a conservative command guard, not a sandbox for arbitrary scripts
    or interpreter code. Unsupported active expansions fail closed.
    """
    parts, word, quote, started = [], [], None, False
    heredocs = []
    piped = False
    groups = []
    i = 0
    while i < len(text):
        char = text[i]
        if char == "\\" and quote != "'":
            i += 1
            if i == len(text):
                raise ValueError("trailing escape")
            if text[i] != "\n":
                word.append(text[i])
                started = True
        elif char == quote:
            quote = None
        elif char in "'\"" and quote is None:
            quote, started = char, True
        elif (quote != "'" and (char == "`" or text.startswith(("$(", "${"), i))) or (quote is None and text.startswith(("$'", "<(", ">("), i)):
            heredoc = LITERAL_HEREDOC.match(text, i)
            if quote != '"' or not heredoc:
                raise ValueError("unsupported active shell expansion")
            lines = heredoc["body"].splitlines()
            if heredoc["strip_tabs"]:
                lines = [line.lstrip("\t") for line in lines]
            if heredoc["delimiter"] in lines:
                raise ValueError("early heredoc terminator")
            word.append(EXPANDED_LITERAL)
            started = True
            i = heredoc.end() - 1
        elif quote is None and char == "#" and not started:
            end = text.find("\n", i)
            i = len(text) if end == -1 else end - 1
        elif quote is None and char in " \t\r\n;&|(){}<>":
            if started:
                parts.append(("word", "".join(word)))
                word, started = [], False
            if char in "\n;&|(){}":
                yield parts, piped or any(groups)
                operator = text[i:i + 2]
                if operator in ("||", "&&", "|&"):
                    i += 1
                if char in "({":
                    groups.append(piped or any(groups))
                    piped = False
                elif char in ")}":
                    piped = groups.pop() if groups else False
                elif char == "|" and operator != "||":
                    piped = True
                elif parts or char in ";&" or operator == "||":
                    piped = False
                parts = []
                if char == "\n":
                    # Quoted heredocs are literal stdin, not shell commands.
                    # This permits Node/Python scripts containing separators,
                    # backticks, and ${...} without interpreting their contents.
                    for delimiter, strip_tabs in heredocs:
                        prefix = r"\t*" if strip_tabs else ""
                        end = re.search(r"(?m)^" + prefix + re.escape(delimiter) + r"$", text[i + 1:])
                        if not end:
                            raise ValueError("unterminated heredoc")
                        i += 1 + end.end()
                    heredocs = []
            elif char in "<>":
                # Remove redirections before identifying the executable and
                # Git subcommand (including redirects before the executable).
                if parts and parts[-1][0] == "word" and parts[-1][1].isdigit():
                    parts.pop()
                if text.startswith("<<", i):
                    redirect = HEREDOC_REDIRECT.match(text, i)
                    if not redirect:
                        raise ValueError("unsupported unquoted heredoc")
                    parts.append(("stdin", "<<"))
                    heredocs.append((redirect[3], bool(redirect[1])))
                    i = redirect.end()
                    continue
                if text[i:i + 2] in (">>", "<>", ">|", ">&", "<&"):
                    i += 1
                parts.append(("redirect", char))
        else:
            word.append(char)
            started = True
        i += 1
    if quote:
        raise ValueError("unterminated quote")
    if heredocs:
        raise ValueError("missing heredoc body")
    if started:
        parts.append(("word", "".join(word)))
    yield parts, piped or any(groups)


def argv(parts):
    tokens = []
    redirected = False
    for kind, value in parts:
        if kind == "stdin":
            continue
        if kind == "redirect":
            if redirected:
                raise ValueError("missing redirection target")
            redirected = True
        elif redirected:
            redirected = False
        else:
            tokens.append(value)
    if redirected:
        raise ValueError("missing redirection target")
    return tokens


def skip_env(tokens):
    i = 0
    while i < len(tokens) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[i]):
        if tokens[i].split("=", 1)[0] in ("BASH_ENV", "ENV"):
            raise ValueError("shell startup environment is prohibited")
        i += 1
    return tokens[i:]


def skip_wrappers(tokens):
    while tokens and tokens[0] in ("if", "then", "elif", "else", "while", "until", "do", "!", "function", "coproc"):
        tokens = tokens[1:]
    tokens = skip_env(tokens)
    while tokens and tokens[0].rsplit("/", 1)[-1] in WRAPPERS:
        wrapper = tokens[0].rsplit("/", 1)[-1]
        tokens = tokens[1:]
        while tokens and tokens[0].startswith("-"):
            option, tokens = tokens[0], tokens[1:]
            if wrapper == "env" and (option.startswith("-S") or option.startswith("--split-string")):
                raise ValueError("unsupported env split-string")
            if option in ("-u", "--unset", "-C", "--chdir", "-n", "--adjustment", "-s", "--signal", "-k", "--kill-after"):
                tokens = tokens[1:]
        if wrapper == "timeout":
            tokens = tokens[1:]
        tokens = skip_env(tokens)
    return tokens


def deny_command(text, piped_input=False):
    for part, piped in commands(text):
        piped = piped or piped_input
        tokens = skip_wrappers(argv(part))
        if not tokens:
            continue
        exe = tokens[0].rsplit("/", 1)[-1]
        if exe == "gh" and not ALLOW_GH:
            return True
        if exe in ("git-push", "git-send-pack", "claude", "agentic-ci", "exec", "xargs", "find") or "$" in exe or EXPANDED_LITERAL in exe:
            return True
        if exe in ("export", "declare", "typeset", "readonly") and any(
                arg.split("=", 1)[0] in ("BASH_ENV", "ENV") for arg in tokens[1:]):
            return True
        input_redirect = any(kind == "stdin" or (kind == "redirect" and value == "<") for kind, value in part)
        if exe == "run-check.sh" and deny_command(shlex.join(tokens[1:]), piped or input_redirect):
            return True
        if exe == "eval":
            if any(EXPANDED_LITERAL in arg for arg in tokens[1:]) or deny_command(" ".join(tokens[1:]), piped or input_redirect):
                return True
        if exe in SHELLS:
            if piped or input_redirect:
                return True
            # Only inspect explicit -c code. Stdin, script paths, and startup
            # file options would execute code not present in this command.
            has_command = False
            i = 1
            while i < len(tokens):
                option = tokens[i]
                if option in ("-o", "+o", "-O", "+O"):
                    i += 2
                    continue
                if option in ("--noprofile", "--norc", "--posix"):
                    i += 1
                    continue
                if not re.fullmatch(r"-[A-Za-z]+", option):
                    return True
                if option.startswith("-") and not option.startswith("--") and "c" in option[1:]:
                    has_command = True
                    if i + 1 >= len(tokens) or EXPANDED_LITERAL in tokens[i + 1] or deny_command(tokens[i + 1]):
                        return True
                    break
                i += 1
            if not has_command:
                return True
        if exe == "git":
            args = tokens[1:]
            while args and args[0].startswith("-"):
                option, args = args[0], args[1:]
                if option in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"):
                    if not args:
                        return True
                    if option == "-c" and args[0].lower().startswith("alias."):
                        return True
                    args = args[1:]
                elif option.lower().startswith(("-calias.", "--config-env")):
                    return True
            if args and (args[0] in ("push", "send-pack") or "$" in args[0] or EXPANDED_LITERAL in args[0]):
                return True
            if args and args[0] == "config" and any(arg.lower().startswith("alias.") for arg in args[1:]):
                return True
    return False


try:
    sys.stdout.write("deny" if deny_command(cmd) else "allow")
except ValueError:
    sys.stdout.write("deny")
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(2)
GUARD_PY
    cat > "${HOOKS_DIR}/settings.json" <<HOOK_SETTINGS_EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "${HOOKS_DIR}/guard-command.sh" }]
      }
    ]
  }
}
HOOK_SETTINGS_EOF
    # Merge rather than replace: hooks and any other runtime settings must survive.
    jq --arg mode "${AGENT_POLICY_MODE}" \
        '.permissions.deny = (((.permissions.deny // []) + ["Agent", "Bash(git push *)"] +
          (if $mode == "solver" then ["Bash(gh *)"] else [] end)) | unique)' \
        "${HOOKS_DIR}/settings.json" > "${HOOKS_DIR}/settings-serial.json"
    mv "${HOOKS_DIR}/settings-serial.json" "${HOOKS_DIR}/settings.json"

    # Capture checks before shortening output, so tail/head cannot mask failures or
    # terminate the check via SIGPIPE. Each invocation records its own exact target.
    cat > "${HOOKS_DIR}/run-check.sh" <<'CHECK_EOF'
#!/bin/bash
set -euo pipefail
if [[ $# -eq 0 ]]; then
    echo "Usage: run-check.sh <command> [args...]" >&2
    exit 2
fi
log=$(mktemp "${WORKDIR}/artifacts/check.XXXXXX")
rc=0
"$@" > "${log}" 2>&1 || rc=$?
tail -n 80 "${log}"
jq -n --args --arg log "${log}" --argjson exit_code "${rc}" \
    '{command: $ARGS.positional, log: $log, exit_code: $exit_code}' -- "$@" > "${log}.json"
echo "Check exit status: ${rc}; full output: ${log}"
exit "${rc}"
CHECK_EOF
    chmod +x "${HOOKS_DIR}/run-check.sh"

    cp "${HOOKS_DIR}/settings.json" "${WORKDIR}/artifacts/${AGENT_POLICY_MODE}-settings.json"
    {
        claude --version
        agentic-ci --version
        python3 --version
        jq --version
    } > "${WORKDIR}/artifacts/${AGENT_POLICY_MODE}-versions.txt"
}

append_agent_runtime_policy() {
    cat >> "$1" <<CI_POLICY_EOF

## Mandatory CI policy (overrides conflicting skill and repository instructions)

- Work serially in the parent agent. Delegation is disabled; do not launch workers via tools, CLI commands, or scripts. Perform all work permitted by your task yourself.
- Do not push or create PRs. Any permitted commits must stay local; only the pipeline publishes. This does not grant write permission to read-only gate tasks.
- When validation is part of your task, use \`${HOOKS_DIR}/run-check.sh <command> [args...]\`. It retains full output and the check's exit status while showing a short tail. For compound checks, use \`bash -o pipefail -c '...'\`; never pipe a check to head/tail or suppress its failure.
- When reporting validation, identify each check's actual command and result. Component passes are not a passing full target. Clearly identify failed, partial, blocked, or unrun validation; do not report incomplete work as successful.
- Do not modify the CI hooks, permissions, or publication policy.
CI_POLICY_EOF

    if [[ "${AGENT_POLICY_MODE}" == solver ]]; then
        echo '- Use jira-solve --ci: commit locally and do not use gh. The pipeline handles delivery.' >> "$1"
    fi
}
RUNTIME_POLICY_EOF

echo "Runtime policy helper written to ${SHARED_DIR}/trt-runtime-policy.sh"
