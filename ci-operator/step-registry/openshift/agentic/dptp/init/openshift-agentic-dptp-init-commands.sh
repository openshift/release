#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== DPTP Init ==="

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
    [[ -f "${SHARED_DIR}/${f}" ]] || { echo "ERROR: ${f} not found in SHARED_DIR. Run dptp-github-app-auth step first."; exit 1; }
done
echo "GitHub tokens validated."

# --- Persist issue key ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"

# --- Fetch Jira issue (authenticated: the DPTP project is not publicly readable) ---
echo "Fetching issue details from Jira..."
# Disable tracing due to API token handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
JIRA_TOKEN="$(cat "/var/run/jira-token/${JIRA_TOKEN_FIELD}")"
curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
    -u "${JIRA_USERNAME}:${JIRA_TOKEN}" \
    "${JIRA_BASE_URL}/rest/api/2/issue/${JIRA_ISSUE_KEY}?fields=summary,description,status,labels,comment,issuetype,priority" \
    > "${SHARED_DIR}/jira-issue.json" || {
    unset JIRA_TOKEN
    $WAS_TRACING && set -x
    echo "ERROR: Failed to fetch issue ${JIRA_ISSUE_KEY} from Jira (check bot read access to the project)."; exit 1;
}
unset JIRA_TOKEN
$WAS_TRACING && set -x

echo "Summary: $(jq -r '.fields.summary // "No summary"' "${SHARED_DIR}/jira-issue.json")"

# --- Telemetry helper for downstream test steps ---
cat > "${SHARED_DIR}/dptp-telemetry.sh" << 'HEREDOC_EOF'
#!/bin/bash
# DPTP agent invocation and telemetry helpers. Source from jira-solver / review-responder:
#   source "${SHARED_DIR}/dptp-telemetry.sh"

EXTRACT_METRICS="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
OTEL_LOG="${ARTIFACT_DIR}/claude-otel.jsonl"

if [[ -f "${SHARED_DIR}/github-app-auth.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/github-app-auth.sh"
fi

# Shared harness selection for both solver and review-responder.
initialize_agent() {
    AGENT_HARNESS="${MULTISTAGE_PARAM_OVERRIDE_AGENT_HARNESS:-${AGENT_HARNESS:-claude-code}}"
    AGENT_EFFORT="${MULTISTAGE_PARAM_OVERRIDE_AGENT_EFFORT:-${AGENT_EFFORT:-high}}"
    case "${AGENT_HARNESS}" in
        claude-code)
            AGENT_DISPLAY_NAME="Claude"
            AGENT_MODEL="${CLAUDE_MODEL}"
            AGENT_GATE_MODEL="${GATE_MODEL:-claude-haiku-4-5}"
            ;;
        codex)
            AGENT_DISPLAY_NAME="Codex"
            AGENT_MODEL="${CODEX_MODEL}"
            AGENT_GATE_MODEL="${CODEX_GATE_MODEL}"
            [[ -r "${OPENAI_API_KEY_PATH}" && -s "${OPENAI_API_KEY_PATH}" ]] || {
                echo "ERROR: Codex API key file is missing or empty" >&2
                return 1
            }
            CODEX_HOME=$(mktemp -d "${HOME}/.dptp-codex.XXXXXX")
            CODEX_AGENT_HOME=$(mktemp -d /tmp/dptp-agent.XXXXXX)
            export CODEX_HOME
            export PATH="/opt/codex/bin:/opt/codex/codex-path:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/lib/golang/bin:/opt/rh/go-toolset/root/usr/bin"
            ;;
        *)
            echo "ERROR: Unsupported AGENT_HARNESS=${AGENT_HARNESS}; expected claude-code or codex" >&2
            return 1
            ;;
    esac
    export AGENT_DISPLAY_NAME
    AGENT_MODEL="${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-${AGENT_MODEL}}"
    AGENT_GATE_MODEL="${MULTISTAGE_PARAM_OVERRIDE_AGENT_GATE_MODEL:-${AGENT_GATE_MODEL}}"
    case "${AGENT_HARNESS}:${AGENT_EFFORT}" in
        claude-code:|claude-code:low|claude-code:medium|claude-code:high|claude-code:xhigh|claude-code:max|codex:|codex:minimal|codex:low|codex:medium|codex:high|codex:xhigh|codex:max) ;;
        *) echo "ERROR: Unsupported effort for ${AGENT_HARNESS}" >&2; return 1 ;;
    esac
    echo "Harness: ${AGENT_HARNESS} | Model: ${AGENT_MODEL} | Effort: ${AGENT_EFFORT:-default}"
}

setup_agent() {
    if [[ "${AGENT_HARNESS}" == "claude-code" ]]; then
        echo "Installing Claude Code..."
        curl -fsSL --retry 3 --retry-delay 5 https://claude.ai/install.sh | sh
        export PATH="${HOME}/.local/bin:${PATH}"
    elif [[ ! -x /opt/codex/bin/codex ]]; then
        echo "ERROR: Codex is missing from the agentic-dev image" >&2
        return 1
    else
        # Authenticated pipeline commands must not resolve edited repo binaries.
        export PATH="/opt/codex/bin:/opt/codex/codex-path:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/lib/golang/bin:/opt/rh/go-toolset/root/usr/bin"
    fi
}

# Command rules supplement the filesystem sandbox; they are not its boundary.
configure_codex_rules() {
    mkdir -p "${CODEX_HOME}/rules"
    cat > "${CODEX_HOME}/rules/dptp.rules" <<'RULES'
prefix_rule(pattern = ["env"], decision = "forbidden")
prefix_rule(pattern = ["printenv"], decision = "forbidden")
prefix_rule(pattern = ["set"], decision = "forbidden")
prefix_rule(pattern = ["git", "config"], decision = "forbidden")
prefix_rule(pattern = ["git", "remote", "-v"], decision = "forbidden")
RULES
    if [[ "${CODEX_DENY_GH:-false}" == "true" ]]; then
        echo 'prefix_rule(pattern = ["gh"], decision = "forbidden")' >> "${CODEX_HOME}/rules/dptp.rules"
    fi
    if [[ "${CODEX_DENY_PUSH:-false}" == "true" ]]; then
        echo 'prefix_rule(pattern = ["git", "push"], decision = "forbidden")' >> "${CODEX_HOME}/rules/dptp.rules"
    fi
}

write_codex_broker_source() {
    cat > "$1" <<'GO_BROKER'
// The step registry only distributes commands.sh. Keep this standalone,
// standard-library-only broker here so init can ship it through SHARED_DIR.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const maxRequestBytes = 2 << 20

var repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
var graphQLWrite = regexp.MustCompile(`\b(mutation|subscription)\b`)

type githubBroker struct {
	repository  string
	pullRequest string
	tokenFile   string
	readOnly    bool
	client      *http.Client
	upstream    string
}

type graphQLRequest struct {
	Query     string                     `json:"query"`
	Variables map[string]json.RawMessage `json:"variables"`
}

func rejectRedirect(_ *http.Request, _ []*http.Request) error {
	return http.ErrUseLastResponse
}

func (b *githubBroker) allowed(method, path string, body []byte) bool {
	if strings.ContainsAny(path, "%\\") || strings.Contains(path, "..") || strings.Contains(path, "//") {
		return false
	}
	if path == "/graphql" {
		var request graphQLRequest
		if method != http.MethodPost || json.Unmarshal(body, &request) != nil || request.Query == "" {
			return false
		}
		// GraphQL reads are needed by gh pr view/checks and the review helper.
		// Never accept a mutation, including in a gate or a multi-operation document.
		return !graphQLWrite.MatchString(request.Query)
	}
	prefix := "/repos/" + b.repository
	if method == http.MethodGet {
		return path == prefix || strings.HasPrefix(path, prefix+"/") || path == "/user" || path == "/rate_limit"
	}
	if b.readOnly || method != http.MethodPost || b.pullRequest == "" {
		return false
	}
	// Workers can reply on this PR, but cannot change repository contents,
	// start Actions, mint tokens, create PRs, or write to another issue.
	if path == prefix+"/issues/"+b.pullRequest+"/comments" || path == prefix+"/pulls/"+b.pullRequest+"/comments" {
		return true
	}
	replyPrefix := prefix + "/pulls/" + b.pullRequest + "/comments/"
	if strings.HasPrefix(path, replyPrefix) && strings.HasSuffix(path, "/replies") {
		comment := strings.TrimSuffix(strings.TrimPrefix(path, replyPrefix), "/replies")
		number, err := strconv.ParseUint(comment, 10, 64)
		return err == nil && number > 0
	}
	return false
}

func (b *githubBroker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// gh treats the loopback host as an Enterprise endpoint.
	path := strings.TrimPrefix(r.URL.EscapedPath(), "/api/v3")
	if path == "/api/graphql" {
		path = "/graphql"
	}
	if r.Method == http.MethodGet && path == "/meta" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"installed_version":"3.16.0"}`)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err != nil {
		http.Error(w, "request too large", http.StatusRequestEntityTooLarge)
		return
	}
	if !b.allowed(r.Method, path, body) {
		http.Error(w, "GitHub operation is outside this worker's scope", http.StatusForbidden)
		return
	}
	token, err := os.ReadFile(b.tokenFile)
	if err != nil || len(bytes.TrimSpace(token)) == 0 {
		http.Error(w, "GitHub credential unavailable", http.StatusServiceUnavailable)
		return
	}
	target := b.upstream + path
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	request, err := http.NewRequestWithContext(r.Context(), r.Method, target, bytes.NewReader(body))
	if err != nil {
		http.Error(w, "invalid GitHub request", http.StatusBadRequest)
		return
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	request.Header.Set("User-Agent", "openshift-dptp-github-broker")
	request.Header.Set("Accept", r.Header.Get("Accept"))
	request.Header.Set("Content-Type", r.Header.Get("Content-Type"))
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	response, err := b.client.Do(request)
	if err != nil {
		// Do not print credentials or authentication-bearing request details.
		http.Error(w, "GitHub request failed", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	for _, header := range []string{"Content-Type", "Link", "Location", "X-RateLimit-Remaining", "X-RateLimit-Reset"} {
		if value := response.Header.Get(header); value != "" {
			if header == "Link" || header == "Location" {
				value = strings.ReplaceAll(value, "https://api.github.com/", "https://"+r.Host+"/api/v3/")
			}
			w.Header().Set(header, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, response.Body)
}

func brokerCertificate() (tls.Certificate, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	certificate := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "DPTP GitHub broker"},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(4 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
		DNSNames:              []string{"localhost", "localhost."},
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}

func runBroker() error {
	repo := flag.String("repo", "", "GitHub repository")
	pr := flag.String("pr", "", "PR allowed to receive replies")
	tokenFile := flag.String("token-file", "", "Private installation token file")
	caFile := flag.String("ca-file", "", "Public CA output file")
	stateFile := flag.String("state-file", "", "Private endpoint output file")
	readOnly := flag.Bool("read-only", false, "Deny all GitHub writes")
	flag.Parse()
	if !repositoryPattern.MatchString(*repo) || *tokenFile == "" || *caFile == "" || *stateFile == "" {
		return errors.New("invalid broker configuration")
	}
	if *pr != "" {
		number, err := strconv.ParseUint(*pr, 10, 64)
		if err != nil || number == 0 {
			return errors.New("invalid PR number")
		}
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	certificate, ca, err := brokerCertificate()
	if err != nil {
		return err
	}
	if err := os.WriteFile(*caFile, ca, 0600); err != nil {
		return err
	}
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		return err
	}
	// Go's HTTP client bypasses proxies for literal loopback addresses and
	// "localhost". The absolute localhost name keeps gh on the sandbox proxy.
	state, err := json.Marshal(map[string]string{"host": net.JoinHostPort("localhost.", port)})
	if err != nil {
		return err
	}
	if err := os.WriteFile(*stateFile, state, 0600); err != nil {
		return err
	}
	broker := &githubBroker{
		repository:  *repo,
		pullRequest: *pr,
		tokenFile:   *tokenFile,
		readOnly:    *readOnly,
		upstream:    "https://api.github.com",
		client:      &http.Client{Timeout: 90 * time.Second, CheckRedirect: rejectRedirect},
	}
	server := &http.Server{Handler: broker, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 120 * time.Second}
	return server.Serve(tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}))
}

func main() {
	if err := runBroker(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
GO_BROKER
}

prepare_codex_isolation() {
    if [[ -e /etc/codex/config.toml ]]; then
        echo 'ERROR: System Codex config could override the isolation profile' >&2
        return 1
    fi
    local workspace sensitive
    workspace=$(realpath "${WORKDIR}") || return 1
    [[ "${workspace}" != / ]] || { echo 'ERROR: Codex workspace cannot be the filesystem root' >&2; return 1; }
    for sensitive in "${SHARED_DIR}" /run "${CODEX_HOME}" "${OPENAI_API_KEY_PATH}"; do
        sensitive=$(realpath "${sensitive}") || return 1
        if [[ "${sensitive}" == "${workspace}" || "${sensitive}" == "${workspace}/"* ]]; then
            echo 'ERROR: Codex workspace overlaps private runtime files' >&2
            return 1
        fi
    done
    # The agent sees this metadata read-only. Disable hooks and fsmonitor before
    # it runs so later pipeline Git operations cannot execute edited repo files.
    git -C "${WORKDIR}" config --local core.hooksPath /dev/null || return 1
    git -C "${WORKDIR}" config --local core.fsmonitor false || return 1
    mkdir -p "${CODEX_AGENT_HOME}/tmp" "${CODEX_AGENT_HOME}/.cache" "${CODEX_AGENT_HOME}/go" "${CODEX_HOME}/inputs"
    if [[ ! -x "${CODEX_HOME}/github-broker" ]]; then
        write_codex_broker_source "${CODEX_HOME}/dptp-github-broker.go"
        GOWORK=off GO111MODULE=off go build -trimpath -o "${CODEX_HOME}/github-broker" "${CODEX_HOME}/dptp-github-broker.go" || return 1
    fi
}

read_codex_artifact() {
    env -i PATH="${PATH}" CODEX_HOME="${CODEX_HOME}" \
        /usr/bin/setpriv --inh-caps=-all --ambient-caps=-all \
        "${CODEX_BIN:-/opt/codex/bin/codex}" sandbox --profile dptp-pipeline \
        --permission-profile dptp --cd "${WORKDIR}" -- /bin/cat "$1"
}

copy_agent_artifacts() {
    if [[ "${AGENT_HARNESS}" == codex ]]; then
        # Resolve source symlinks within the sandbox. A link into a credential
        # mount fails there instead of being followed by the privileged uploader.
        if [[ -f "${CODEX_HOME}/dptp-pipeline.config.toml" ]]; then
            local export_profile="${CODEX_HOME}/dptp-export.config.toml"
            cp "${CODEX_HOME}/dptp-pipeline.config.toml" "${export_profile}" || return 1
            printf '\n[permissions.dptp.filesystem.%s]\n"." = "write"\n' \
                "$(printf '%s' "${ARTIFACT_DIR}" | jq -Rs .)" >> "${export_profile}" || return 1
            # shellcheck disable=SC2016 # Expanded by the sandboxed shell.
            env -i PATH="${PATH}" CODEX_HOME="${CODEX_HOME}" \
                /usr/bin/setpriv --inh-caps=-all --ambient-caps=-all \
                "${CODEX_BIN:-/opt/codex/bin/codex}" sandbox --profile dptp-export \
                --permission-profile dptp --cd "${WORKDIR}" -- \
                /bin/bash --noprofile --norc -c 'cp -L -- "$1/artifacts/"* "$2/"' _ "${WORKDIR}" "${ARTIFACT_DIR}" \
                2>> "${CODEX_HOME}/codex-stderr.log" || echo 'WARNING: Some Codex artifacts could not be exported' >&2
        fi
        cp "${CODEX_HOME}/codex-output.jsonl" "${CODEX_HOME}/codex-stderr.log" "${ARTIFACT_DIR}/" 2>/dev/null || true
    else
        cp "${WORKDIR}/artifacts/"* "${ARTIFACT_DIR}/" 2>/dev/null || true
    fi
}

commit_codex_changes() {
    [[ "${AGENT_HARNESS}" == codex ]] || return 0
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false add --all -- . ':!artifacts' || return 1
    local diff_status=0
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false diff --cached --quiet || diff_status=$?
    if [[ "${diff_status}" -eq 1 ]]; then
        git -c core.hooksPath=/dev/null -c core.fsmonitor=false commit -m "${JIRA_ISSUE_KEY}: ${ISSUE_SUMMARY:-address PR feedback}" || return 1
    elif [[ "${diff_status}" -ne 0 ]]; then
        return "${diff_status}"
    fi
}

cleanup_codex_run() {
    if [[ -n "${broker_pid:-}" ]]; then
        kill "${broker_pid}" 2>/dev/null || true
        wait "${broker_pid}" 2>/dev/null || true
    fi
    [[ -z "${run_dir:-}" ]] || rm -rf "${run_dir}"
}

write_codex_permissions() {
    local profile=$1 github_host=$2
    local workdir_json home_json inputs_json key_json
    workdir_json=$(printf '%s' "${WORKDIR}" | jq -Rs .)
    home_json=$(printf '%s' "${CODEX_AGENT_HOME}" | jq -Rs .)
    inputs_json=$(printf '%s' "${CODEX_HOME}/inputs" | jq -Rs .)
    key_json=$(realpath "${OPENAI_API_KEY_PATH}" | jq -Rs 'rtrimstr("\n")')
    {
    cat <<PERMISSIONS
default_permissions = "dptp"
approval_policy = "never"

[projects.${workdir_json}]
trust_level = "untrusted"

[features]
network_proxy = true

[permissions.dptp.filesystem]
":root" = "deny"
":minimal" = "read"
"/opt" = "read"
"/proc" = "deny"
"/run" = "deny"
${home_json} = "write"
${inputs_json} = "read"
${key_json} = "deny"

[permissions.dptp.filesystem.${workdir_json}]
"." = "write"
".git" = "read"
".codex" = "read"
".agents" = "read"

[permissions.dptp.network]
enabled = true
allow_local_binding = false

[permissions.dptp.network.domains]
"*" = "allow"
"127.0.0.1" = "allow"
"localhost" = "allow"

[shell_environment_policy]
inherit = "none"
PERMISSIONS
    printf 'set = '
    jq -cn --arg home "${CODEX_AGENT_HOME}" --arg inputs "${CODEX_HOME}/inputs" --arg github_host "${github_host}" --arg repository "${UPSTREAM_REPO}" '
        {HOME: $home, TMPDIR: ($home + "/tmp"), XDG_CACHE_HOME: ($home + "/.cache"),
         PATH: "/opt/codex/bin:/opt/codex/codex-path:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/usr/lib/golang/bin:/opt/rh/go-toolset/root/usr/bin",
         GOPATH: ($home + "/go"), GOCACHE: ($home + "/.cache/go-build"),
         BUILDAH_ISOLATION: "chroot", REGISTRY_AUTH_FILE: ($inputs + "/registry-auth.json"),
         GH_HOST: $github_host, GH_ENTERPRISE_TOKEN: "dptp-broker-placeholder",
         GH_REPO: ($github_host + "/" + $repository),
         SSL_CERT_FILE: ($inputs + "/ca-bundle.pem"), GIT_SSL_CAINFO: ($inputs + "/ca-bundle.pem"),
         GIT_CONFIG_GLOBAL: ($inputs + "/gitconfig"), GIT_CONFIG_NOSYSTEM: "1",
         LANG: "C.UTF-8"} | to_entries | map((.key|@json) + " = " + (.value|@json)) | "{ " + join(", ") + " }"
    ' -r
    } >> "${profile}"
}

run_codex() (
    local timeout_seconds=$1 model=$2 prompt=$3
    shift 3
    local output_format=stream-json resume=false
    local instructions_config="${CODEX_HOME}/dptp-instructions.toml"
    local profile="${CODEX_HOME}/dptp-pipeline.config.toml"
    local system_prompt_file=""
    local broker_pid="" run_dir=""
    trap cleanup_codex_run EXIT
    # The nested-podman SCC gives non-root processes ambient SETUID/SETGID.
    # Bubblewrap rejects such capabilities; clear them before executing Codex.
    local -a cmd=(/usr/bin/setpriv --inh-caps=-all --ambient-caps=-all
        "${CODEX_BIN:-/opt/codex/bin/codex}" exec --json
        -c 'approval_policy="never"' -c 'default_permissions="dptp"' --model "${model}")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --append-system-prompt-file)
                system_prompt_file=$2
                [[ -r "${system_prompt_file}" ]] || return 1
                shift 2
                ;;
            --output-format) output_format=$2; shift 2 ;;
            --continue) resume=true; shift ;;
            --max-turns) shift 2 ;; # Codex is bounded by the outer timeout.
            --settings) shift 2 ;; # Replaced by configure_codex_rules.
            --disallowedTools)
                shift
                while [[ $# -gt 0 && "$1" != --* ]]; do shift; done
                ;;
            *) echo "ERROR: Unsupported Codex adapter argument: $1" >&2; return 2 ;;
        esac
    done
    if [[ -n "${AGENT_EFFORT}" ]]; then
        cmd+=(-c "model_reasoning_effort=${AGENT_EFFORT}")
    fi
    if [[ -n "${system_prompt_file}" ]] || ! ${resume}; then
        touch "${instructions_config}" || return 1
        chmod 600 "${instructions_config}" || return 1
        {
            printf 'developer_instructions = '
            {
                printf '%s\n\n' 'Use shell commands and file tools to carry out the inlined process. Read referenced SKILL.md files directly; do not invoke Claude-only Skill or slash commands.'
                if [[ -n "${system_prompt_file}" ]]; then
                    cat "${system_prompt_file}"
                fi
                printf '\n\n%s\n' 'Codex CI isolation: edit and test workspace files only. Git metadata is read-only. Do not create branches, commit, push, pull, or run git fetch. The pipeline handles commits and pushes. GitHub access uses a scoped broker: read metadata and post replies only; do not invoke GraphQL mutations or gh auth commands. Credentials are deliberately unavailable to commands.'
            } | jq -Rs .
        } > "${instructions_config}" || return 1
    fi
    # A named profile keeps large instructions out of argv and preserves them
    # at developer priority on resume, without replacing the base user config.
    prepare_codex_isolation || return 1
    local github_host="127.0.0.1:1"
    local broker_state="${CODEX_HOME}/broker-state.json"
    local broker_ca="${CODEX_HOME}/inputs/github-ca.pem"
    local broker_args=()
    if [[ "${CODEX_DENY_GH:-false}" != true ]]; then
        [[ -n "${PR_NUM:-}" ]] || { echo 'ERROR: PR_NUM is required for the GitHub broker' >&2; return 1; }
        [[ "${CODEX_BROKER_READ_ONLY:-false}" == true ]] && broker_args+=(--read-only)
        rm -f "${broker_state}"
        "${CODEX_HOME}/github-broker" --repo "${UPSTREAM_REPO}" --pr "${PR_NUM}" \
            --token-file "${SHARED_DIR}/gh-upstream-token" --ca-file "${broker_ca}" \
            --state-file "${broker_state}" "${broker_args[@]}" \
            2>> "${CODEX_HOME}/codex-stderr.log" &
        broker_pid=$!
        local attempt
        for attempt in {1..100}; do
            [[ -s "${broker_state}" ]] && break
            if ! kill -0 "${broker_pid}" 2>/dev/null; then
                echo "ERROR: GitHub broker failed to start (attempt ${attempt})" >&2
                return 1
            fi
            sleep 0.1
        done
        if [[ ! -s "${broker_state}" ]]; then
            kill "${broker_pid}" 2>/dev/null || true
            wait "${broker_pid}" 2>/dev/null || true
            echo 'ERROR: GitHub broker startup timed out' >&2
            return 1
        fi
        github_host=$(jq -er '.host' "${broker_state}") || return 1
    fi
    local system_ca="" candidate
    for candidate in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
        if [[ -r "${candidate}" ]]; then
            system_ca="${candidate}"
            break
        fi
    done
    [[ -n "${system_ca}" ]] || { echo 'ERROR: System CA bundle not found' >&2; return 1; }
    cat "${system_ca}" > "${CODEX_HOME}/inputs/ca-bundle.pem" || return 1
    if [[ -f "${broker_ca}" ]]; then
        cat "${broker_ca}" >> "${CODEX_HOME}/inputs/ca-bundle.pem" || return 1
    fi
    printf '{"auths":{}}\n' > "${CODEX_HOME}/inputs/registry-auth.json" || return 1
    git config --file "${CODEX_HOME}/inputs/gitconfig" safe.directory "${WORKDIR}" || return 1
    touch "${profile}" || return 1
    chmod 600 "${profile}" || return 1
    cat "${instructions_config}" > "${profile}" || return 1
    write_codex_permissions "${profile}" "${github_host}" || return 1
    cmd+=(--profile dptp-pipeline)
    configure_codex_rules || return 1
    # Each step has its own CODEX_HOME; --last can only resume its own worker.
    if ${resume}; then
        cmd+=(resume --last)
    fi
    local rc=0 was_tracing=false
    run_dir=$(mktemp -d /tmp/dptp-codex-run.XXXXXX) || return 1
    cmd+=(--output-last-message "${run_dir}/last-message" -)
    # The key is scoped to the CLI process. Never trace its expansion.
    [[ $- == *x* ]] && was_tracing=true
    set +x
    if [[ "${output_format}" == text ]]; then
        CODEX_API_KEY=$(<"${OPENAI_API_KEY_PATH}") timeout --kill-after=30 "${timeout_seconds}" "${cmd[@]}" \
            <<< "${prompt}" >> "${CODEX_HOME}/codex-output.jsonl" \
            2>> "${CODEX_HOME}/codex-stderr.log" || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            cat "${run_dir}/last-message" || rc=$?
        fi
    else
        CODEX_API_KEY=$(<"${OPENAI_API_KEY_PATH}") timeout --kill-after=30 "${timeout_seconds}" "${cmd[@]}" \
            <<< "${prompt}" 2>> "${CODEX_HOME}/codex-stderr.log" \
            | tee -a "${CODEX_HOME}/codex-output.jsonl" || rc=$?
    fi
    ${was_tracing} && set -x
    return "${rc}"
)

agent_gate() {
    local prompt=$1
    if [[ "${AGENT_HARNESS}" == codex ]]; then
        refresh_github_tokens || return 1
        CODEX_BROKER_READ_ONLY=true run_codex 120 "${AGENT_GATE_MODEL}" "${prompt}" \
            --append-system-prompt-file "${GATE_PROMPT}" --output-format text
    else
        # The gate's markers must come from plain text, not stream-json.
        timeout 120 claude --model "${AGENT_GATE_MODEL}" \
            --allowedTools Bash --disallowedTools "${DISALLOWED_TOOLS[@]}" \
            --max-turns 20 --output-format text \
            --append-system-prompt-file "${GATE_PROMPT}" -p "${prompt}" --verbose
    fi
}

agentic_ci() {
    # Installation tokens last 1h; mint a fresh one before each long child.
    if declare -F refresh_github_tokens >/dev/null 2>&1; then
        if ! refresh_github_tokens; then
            if [[ "${AGENT_HARNESS}" == codex ]]; then
                echo 'ERROR: Scoped GitHub token refresh failed' >&2
                return 1
            fi
            echo "WARNING: GitHub App token refresh failed; continuing with existing tokens"
        fi
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
    if [[ "${AGENT_HARNESS}" == codex ]]; then
        if [[ ${#extra_args[@]} -gt 0 ]]; then
            echo "ERROR: agentic-ci wrapper options are unsupported for Codex" >&2
            return 2
        fi
        run_codex "${timeout_seconds:-5400}" "${AGENT_MODEL}" "${prompt}" "$@"
        return $?
    fi
    local effort_args=()
    if [[ -n "${AGENT_EFFORT}" ]]; then
        effort_args=(--effort "${AGENT_EFFORT}")
    fi
    local cmd=(
        agentic-ci run
        --backend local
        --harness claude-code
        --model "${AGENT_MODEL}"
        --workdir "${WORKDIR}"
        "${extra_args[@]+"${extra_args[@]}"}"
        "${prompt}"
        --
        --permission-mode default
        --allowedTools "${ALLOWED_TOOLS}"
        --verbose
        "${effort_args[@]}"
        "$@"
    )
    local run_tmp
    run_tmp=$(mktemp -d /tmp/agentic-ci-wrapper.XXXXXX)
    local rc=0
    if [[ -n "${timeout_seconds}" ]]; then
        TMPDIR="${run_tmp}" timeout "${timeout_seconds}" "${cmd[@]}" 2>&1 | tee -a "${WORKDIR}/artifacts/claude-output.log" || rc=${PIPESTATUS[0]}
    else
        TMPDIR="${run_tmp}" "${cmd[@]}" 2>&1 | tee -a "${WORKDIR}/artifacts/claude-output.log" || rc=${PIPESTATUS[0]}
    fi
    find "${run_tmp}" -name 'claude-otel.jsonl' -type f -exec cat {} + >> "${OTEL_LOG}" 2>/dev/null || true
    rm -rf "${run_tmp}"
    return "$rc"
}

finalize_session_metrics() {
    if [[ "${AGENT_HARNESS:-claude-code}" == codex ]]; then
        # The existing extractor accepts Claude OTEL only. Keep Codex JSONL
        # artifacts without publishing misleading Claude token/cost rows.
        return 0
    fi
    rm -f "${SHARED_DIR}/claude-otel.jsonl"
    if [[ ! -f "${EXTRACT_METRICS}" ]]; then
        echo "Warning: extract_metrics.py not found, skipping session metrics"
        return 0
    fi
    if [[ ! -s "${OTEL_LOG}" ]]; then
        echo "Warning: No OTEL data collected, skipping session metrics"
        return 0
    fi
    local metrics_tmp
    metrics_tmp=$(mktemp)
    if ! python3 "${EXTRACT_METRICS}" "${OTEL_LOG}" "${metrics_tmp}" 2>&1; then
        echo "Warning: Failed to extract session metrics"
        rm -f "${metrics_tmp}"
        return 0
    fi
    cp "${metrics_tmp}" "${SHARED_DIR}/claude-session-metrics-autodl.json"
    rm -f "${metrics_tmp}"
    echo "Session metrics autodl written to ${SHARED_DIR}/claude-session-metrics-autodl.json"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/dptp-telemetry.sh"
echo "Telemetry helper written to ${SHARED_DIR}/dptp-telemetry.sh"

echo "=== DPTP Init Complete ==="
