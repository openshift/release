# DPTP agent workflows

The Jira solver and PR follow-up workflows support `claude-code` (the default)
and headless `codex`. The same selection applies to the solver, review gate,
review-comment worker, and CI-failure worker. GitHub App authentication, Jira
fetching, PR creation, polling, and verified fork pushes stay in the pipeline.

Select a harness in the consuming job's `steps.env`:

```yaml
AGENT_HARNESS: codex
CODEX_MODEL: gpt-5.6-sol
CODEX_GATE_MODEL: gpt-5.6-sol
AGENT_EFFORT: high
```

For an individual Gangway run, use `pod_spec_options.envs`:

```json
{
  "MULTISTAGE_PARAM_OVERRIDE_AGENT_HARNESS": "codex",
  "MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL": "gpt-5.6-sol",
  "MULTISTAGE_PARAM_OVERRIDE_AGENT_GATE_MODEL": "gpt-5.6-sol",
  "MULTISTAGE_PARAM_OVERRIDE_AGENT_EFFORT": "high"
}
```

Set the harness override to `claude-code` to switch back. Omit the model and
effort overrides to use the harness defaults. Effort defaults to `high` for both
harnesses. `CLAUDE_MODEL` and `GATE_MODEL`
remain the Claude worker and gate defaults; `CODEX_MODEL` and `CODEX_GATE_MODEL`
are their Codex equivalents. Model and effort values must be supported by the
selected provider and account.

Codex reads the API key from `/var/run/codex-openai-api-key/token`, mounted from
`ci-claude-code/codex-openshift-ci`, as in the payload-agent step. DPTP
`agentic-dev` images install the complete Codex 0.149.0 package from its pinned
upstream release and verify the archive against architecture-specific SHA-256
checksums. The CLI runs directly with `codex exec`; Claude keeps
using the existing `agentic-ci` wrapper.

Both harnesses receive the same inlined process and repository guidance.
Codex receives that guidance as developer instructions and retains it on resume.
The guidance is stored in a private temporary profile under `CODEX_HOME`, so Jira
descriptions and comments do not count toward command-line argument size limits.
Codex uses a Linux filesystem sandbox with access denied by default. Commands
can read system tools and ai-helpers, edit workspace files, and use a fresh home
and cache. Git metadata and pipeline-provided inputs are read-only. Credential
mounts, shared token files, the supervisor's private configuration, and its
environment are unavailable to commands. Shell environments use an explicit
allow-list, and project-local Codex configuration is untrusted. Unsupported
sandbox operations fail closed; there is no full-access fallback.

The pipeline creates Codex's feature branch, commits its edits with hooks and
fsmonitor disabled, and pushes after the worker succeeds. Existing fork/head
verification still applies to review pushes. Codex cannot commit or push itself.
PR descriptions and workspace artifacts are read through the sandbox so links
to private files cannot make the publisher disclose credentials. Supervisor
logs stay outside the writable workspace until publication.

Codex refreshes GitHub App tokens with access restricted to the configured
repositories. A trusted, loopback-only HTTPS broker holds the upstream token
outside the command sandbox. `gh` receives a placeholder token and can read
GitHub metadata; review workers can post comments/replies only on the selected
PR. Gates cannot write. GraphQL mutations and other authenticated writes are
rejected. Pagination stays on the broker. The OpenAI key remains in the trusted
Codex supervisor, and the broker's TLS private key stays in its memory.

The command network proxy allows public network access and the local broker,
while blocking direct connections and unapproved private/link-local targets.
Commands receive an empty registry-auth file. Any required private-image pulls
must happen in trusted setup before the agent runs; registry credentials are
never exposed to agent commands. Native command rules additionally deny `gh`
in the solver and `git push` in review workers.

Codex JSONL events and diagnostics are retained as `codex-output.jsonl` and
`codex-stderr.log`. Gate decisions are read only from Codex's final message.
Solve metadata and JUnit labels identify the selected harness. Claude's OTEL
extractor is skipped for Codex; Codex token/cost data is not submitted as Claude
session metrics.

Run the offline adapter checks with:

```bash
bash hack/test-dptp-agent-harness.sh
```

Run the native isolation fixture in a DPTP image with Linux user namespaces
enabled (the CI jobs use the `nested-podman` SCC):

```bash
bash hack/test-dptp-codex-isolation.sh
```

It uses a local Responses fixture and fake credentials to check filesystem and
environment isolation, protected Git metadata, broker connectivity, pipeline
commits, and artifact/PR-description symlink handling without model API calls.

The harnesses do not have identical options or telemetry:

| Setting or output | Claude | Codex |
| --- | --- | --- |
| Worker/gate model overrides | Supported | Supported |
| Worker effort | `--effort`, default `high` | `model_reasoning_effort`, default `high` |
| Gate effort | Provider default | Uses `AGENT_EFFORT` |
| Continuation | `--continue` | `exec resume --last` within the step's isolated home |
| Turn limit | `--max-turns` | No CLI equivalent; outer timeout applies |
| Tool permissions | `ALLOWED_TOOLS`, denials, solver hook | Default-deny filesystem sandbox, clean environment, network proxy, scoped GitHub broker, and command rules |
| Commits and pushes | Solver commits/pushes; review pipeline pushes | Pipeline commits and pushes; agent Git metadata is read-only |
| Process instructions | Appended system prompt file | Developer instructions |
| Domain results and phase timings | Published | Published |
| Session tokens, cost, API timing, tool telemetry | Claude OTEL exporter | Raw JSONL only; no equivalent exporter yet |

A successful rehearsal is required to establish live provider/model access and
end-to-end behavior. Offline adapter tests and the pinned CLI smoke test do not
establish telemetry parity.
