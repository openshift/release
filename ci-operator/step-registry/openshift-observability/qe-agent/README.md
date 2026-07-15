# openshift-observability-qe-agent

Agentic post-step for OpenShift Observability teams that autonomously triages e2e test failures using Claude Code CLI.

When a test step reports failures, the agent reads the JUnit XML reports and a context file from `SHARED_DIR`, then runs Claude with a team-provided skill to diagnose the root cause and — depending on the skill — attempt remediation (re-run failing tests, propose a fix, write a bug report, etc.).

The step is a **no-op** (exits immediately with no cost) when:
- `AGENT_SKILL` is not set
- `SHARED_DIR/qe-agent-context.json` is absent (test step did not run or skipped the trap)
- `has_test_failures` in the context file is `false` (all tests passed)

Claude's full session output (stream-json) is captured to a temporary file and never written to the CI build-log or uploaded to GCS. Two derived artifacts are extracted from it and saved to `ARTIFACT_DIR` after the session completes: a cost/usage record and a tool call audit log (see [Audit artifacts](#audit-artifacts)).

---

## Quick Start

1. Tag your test runner image as `obs-tests-runner` and install Claude Code CLI in it
2. Add the `notify_qe_agent` EXIT trap to your test step script
3. Add `openshift-observability-qe-agent` to the `post:` phase of your CI config
4. Set `AGENT_SKILL` to your team's skill name

See [Setup](#setup) for detailed instructions.

---

## Agent Persona and Purpose

**Role**: Autonomous QE test failure triage agent for OpenShift Observability operators.

**Goals**:
- Diagnose root cause of e2e test failures (product bug, test issue, flaky test, cluster instability)
- Rerun failing tests to confirm reproducibility and detect flakiness
- Apply minimal test fixes for test issues and export them for human review
- Write structured bug reports for product defects
- Produce analysis summaries with evidence citations

**Operational context**: Runs as a CI post-step inside an already-provisioned OpenShift test cluster. The environment is ephemeral — the cluster is destroyed after each job. The agent operates non-interactively with no human supervision during execution. All output is written to files for post-run human review.

---

## Why use this step

The traditional workflow for debugging a CI test failure is:

1. Provision a new cluster (~30-45 minutes)
2. Set up the test environment (operators, dependencies, configuration)
3. Run the failing test suite
4. Inspect logs and iterate

End-to-end this typically takes **1-2 hours of cluster time**, which at OpenShift CI cloud rates is substantially more expensive than the AI API cost — and requires an engineer's attention throughout.

The qe-agent step runs **inside the already-provisioned CI job**, against the cluster that just ran the tests. The environment is already set up. The failing test artifacts are already present. Claude reruns the exact failing tests, collects diagnostics, and produces a root-cause analysis and proposed fix — all autonomously, at a cost of **$3-5 in AI API spend** per run based on observed production runs.

The cost can be reduced further by:
- Implementing cross-run pattern awareness using Sippy to skip analysis for known failures
- Reducing the rerun count in the flakiness confirmation loop
- Switching to a smaller model for simpler triage tasks

Even at the current ceiling of $5, a single qe-agent run replaces most of the value of a 1-2 hour manual debug session on a freshly provisioned cluster.

> **Where to add this step**: Target upstream testing CI jobs first, not the full job matrix. Upstream jobs run against the latest operator and test code, so they surface both product regressions and test issues at the earliest point in the development cycle — exactly where autonomous triage adds the most value. Adding the step to every job (stage, product, multi-arch, disconnected) spreads AI budget across runs where failures are often already understood, and increases noise before the step has proven itself in your environment. Until cross-run pattern awareness via Sippy is implemented — preventing the agent from running against failures that are already known and tracked — keep the step limited to upstream jobs where each failure is more likely to be novel and worth investigating.

---

## Limitations

- **Prompt-level constraints only**: File output paths and scope are enforced by skill instructions (system prompt), not technical sandboxing. The agent _could_ write outside `ARTIFACT_DIR` — the skill tells it not to, but this is not technically enforced.
- **No cross-run pattern awareness**: Sippy integration is not yet implemented. The agent analyzes every failure independently, even if it is a known issue already tracked in Jira.
- **Cloud-provisioned clusters prohibited**: The agent must not be used with GCP/AWS/Azure clusters — see [Blast Radius and Risk Profile](#blast-radius-and-risk-profile).
- **Maximum 3 individual test analyses**: When more than 5 tests fail and no common pattern is found, the agent caps analysis at 3 tests.
- **Hard budget and time limits**: `$5 USD` spend cap and `90-minute` wall-clock timeout may truncate analysis of complex multi-failure scenarios.
- **Skill fetch from GitHub main branch**: A bad merge to the skill file could affect agent behavior until reverted. Skills are fetched at runtime, not baked into the image.
- **No interactive debugging**: The agent runs non-interactively. It cannot ask clarifying questions or request human input during execution.

---

## Setup

There are four things you need to do to adopt this step for your team.

### 1. Tag your test runner image as `obs-tests-runner`

The qe-agent step runs in the same container image used by your test step (`from: obs-tests-runner`). This means the image must have all the tools needed to execute your test suite **and** the Claude Code CLI.

In your `ci-operator/config` file, tag the test Dockerfile build output as `obs-tests-runner`:

```yaml
images:
  - context_dir: .
    dockerfile_path: tests/Dockerfile   # your test runner Dockerfile
    to: obs-tests-runner
```

### 2. Install Claude Code CLI in your test runner Dockerfile

Add one of the following installation blocks to your test runner Dockerfile, depending on the base image's package manager.

#### Debian / Ubuntu (apt)

```dockerfile
# Install Claude Code CLI via signed apt repository
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
         -o /etc/apt/keyrings/claude-code.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
         > /etc/apt/sources.list.d/claude-code.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends claude-code \
    && rm -rf /var/lib/apt/lists/*
```

#### RHEL / Fedora / CentOS (dnf)

```dockerfile
# Install Claude Code CLI via signed dnf repository
RUN curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
         -o /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-code \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-code \
    && echo -e "[claude-code]\nname=Claude Code\nbaseurl=https://downloads.claude.ai/claude-code/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-claude-code" \
         > /etc/yum.repos.d/claude-code.repo \
    && dnf install -y claude-code \
    && dnf clean all
```

### 3. Add the `notify_qe_agent` EXIT trap to your test step script

`SHARED_DIR` only propagates **flat files** between steps — subdirectories created in one step's pod are not visible in subsequent post step pods. The trap below writes the context file and JUnit XMLs as flat files to `SHARED_DIR` on exit, regardless of whether the test step passed or failed.

Add this function and trap near the top of your test step `*-commands.sh` script, before any test execution:

```bash
# Write a flat context file and JUnit XMLs to SHARED_DIR for the qe-agent post-step.
# SHARED_DIR only supports flat files (no subdirectories); subdirs are not propagated between steps.
function notify_qe_agent() {
    local has_failures=false
    grep -rqE '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true

    local i=0
    while IFS= read -r xml; do
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "step_script_ref": "<org>/<repo>/path/to/your-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "EXAMPLE_VAR": "${EXAMPLE_VAR:-}"
  }
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT
```

Replace `step_script_ref` with the path to your commands script relative to the repository root, and populate `env` with any variables the skill needs to re-run or reproduce the failure.

> **Note on JUnit XML size**: `SHARED_DIR` is backed by a Kubernetes Secret with a 1 MiB limit shared across all files. JUnit XMLs are safe to copy; do **not** copy binary artifacts such as Cypress screenshots.

### 4. Add the step and set `AGENT_SKILL` in your CI config

Add `openshift-observability-qe-agent` to the `post:` phase of your test and set `AGENT_SKILL` in the `env:` block to your team's skill name:

```yaml
tests:
- as: my-upstream-tests
  steps:
    cluster_profile: <non-cloud-profile>
    env:
      AGENT_SKILL: MY_TEAM
      # ... other env vars
    post:
    - ref: openshift-observability-qe-agent
    - chain: <your-deprovision-chain>
    test:
    - ref: <your-test-ref>
    workflow: <non-cloud-workflow>
```

> **Important**: Do not use cloud-provisioned clusters (GCP, AWS, Azure) with this step. See [Blast Radius and Risk Profile](#blast-radius-and-risk-profile) for details.

---

## Agent Skill

Skills are Markdown files hosted in this step's `skills/` directory within the `openshift/release` repository:

```text
ci-operator/step-registry/openshift-observability/qe-agent/skills/
├── OTEL.md          <- OpenTelemetry Operator (junit_otel_* tests, chainsaw)
├── TEMPO.md         <- Tempo Operator (junit_tempo_* tests, chainsaw)
├── TRACING_UI.md    <- Distributed Tracing Console Plugin (Cypress)
├── DISCONNECTED.md  <- Distributed Tracing disconnected suite (chainsaw)
└── OWNERS
```

Each skill is fetched at runtime from `https://raw.githubusercontent.com/openshift/release/main/...` and passed to Claude as its system prompt. The skill defines how Claude should approach the failure: what tests to re-run, what logs to collect, how to classify the root cause, and what output to produce.

### Adding a new team skill

1. Create `ci-operator/step-registry/openshift-observability/qe-agent/skills/<TEAM_NAME>.md`
2. Add your team identifier to the `OWNERS` file in `skills/`
3. Validate the skill before submitting (see [Skill validation](#skill-validation))
4. Open a PR to `openshift/release` — the step OWNERS review and approve it
5. Set `AGENT_SKILL: <TEAM_NAME>` in your CI config

Skill names must be alphanumeric (hyphens and underscores allowed). The step rejects any value that does not match `^[A-Za-z0-9_-]+$` to prevent path traversal.

### Skill validation

Before submitting a new or modified skill, validate it with the following tools:

**[Skillsaw](https://github.com/stbenjam/skillsaw)** — Linter for AI agent instruction files. Checks for security issues (embedded secrets, dangerous patterns), content quality (weak language, contradictions, attention dead zones), and structural correctness (frontmatter, instruction budget). Run it against your skill file before opening a PR:

```bash
pip install skillsaw
skillsaw lint ci-operator/step-registry/openshift-observability/qe-agent/skills/
```

**[Agent Eval Harness](https://github.com/opendatahub-io/agent-eval-harness)** — Evaluation framework for testing AI agent skill effectiveness. Use it to measure how well your skill performs against known test failure scenarios before deploying to CI:

```bash
pip install agent-eval-harness
```

Both tools help catch issues early — Skillsaw identifies security risks and content quality problems in the skill definition, while Agent Eval Harness validates that the skill produces correct and useful results when executed.

### AGENT_SKILL

| Property | Value |
|---|---|
| Required | Yes |
| Format | Alphanumeric, hyphens, underscores only |
| Resolves to | `ci-operator/step-registry/openshift-observability/qe-agent/skills/<name>.md` in `openshift/release` |
| Example | `TEMPO` |

---

## Blast Radius and Risk Profile

This step grants Claude Code CLI unrestricted Bash access inside a CI pod that holds live cluster credentials. Before adopting it, understand what Claude can and cannot do.

### Cluster requirement: non-cloud provisioned clusters only

This step **must not be used with cloud-provisioned test clusters** (GCP, AWS, Azure, etc.). Cloud-provisioned clusters store cloud provider credentials in `kube-system` and `openshift-*` namespaces. Because the agent runs with cluster-admin privileges, it could read those credentials. Kubernetes RBAC is purely additive (no deny rules), so there is no way to grant cluster-admin while blocking secret reads in specific namespaces.

Use non-cloud provisioned clusters (e.g., bare metal) where no cloud provider credentials are stored in the cluster, eliminating this risk entirely.

### What Claude can do

| Capability | Scope |
|---|---|
| Run shell commands | Full pod OS access (non-root). No explicit sandbox — the skill file is the constraint. |
| `kubectl` / `oc` | Any operation allowed by the pod's service account RBAC: create, delete, patch namespaces, pods, ClusterRoles, CSVs, CRDs, and more. |
| Read files | Any file visible to the pod process, including mounted secrets, `KUBECONFIG`, `SHARED_DIR`, and `ARTIFACT_DIR`. |
| Write files | Anything writable by the pod: `ARTIFACT_DIR` (uploaded to GCS), `SHARED_DIR` (shared with other post-steps), `/tmp`. |
| Clone git repos | Network access to GitHub is available; the skill instructs `git clone` during test environment setup. |

### What Claude cannot do

- **No cloud credential access** — non-cloud provisioned clusters have no cloud provider credentials stored in the cluster. There are no GCP service account keys, AWS IAM credentials, or Azure service principal secrets for Claude to read.
- **No outbound HTTP** — `WebFetch` is not in `allowedTools`; Claude cannot call arbitrary external URLs.
- **No git push** — no git credentials are mounted; file changes are confined to the pod.
- **No cross-tenant cluster access** — RBAC bounds apply; Claude cannot reach other teams' clusters or namespaces.
- **No persistence beyond the job** — the test cluster is ephemeral and torn down by the deprovision chain after every job.

### Worst-case scenarios

**Unexpected cluster mutation** — Claude misinterprets a skill step and deletes a namespace or patches a resource it should not touch. Not a concern in practice: the step runs in the `post:` phase against a test-only cluster, and the deprovision chain that follows destroys the entire cluster regardless. No production or shared infrastructure is reachable.

**Runaway session** — Claude enters a reasoning loop, consuming turns and Vertex AI budget without making progress. Hard-bounded on two axes: `--max-budget-usd 5` stops the session the moment spend reaches $5 — preventing runaway cost from exhausting the Vertex AI cost center budget — and the 90-minute wall-clock timeout is the outer limit. `best_effort: true` ensures neither bound can block the pipeline.

**ARTIFACT_DIR pollution** — Claude writes unexpected files to `ARTIFACT_DIR`, which are then uploaded to GCS. The skill scopes Claude to documented output paths, but this is a prompt-level control, not a technical one.

**SHARED_DIR pollution** — Claude writes unexpected files to `SHARED_DIR`, which is shared with the deprovision post-step. The deprovision step ignores unexpected files in practice, but this is not formally enforced.

### Audit artifacts

After every run, two files are written to `ARTIFACT_DIR` for post-incident review:

| File | Contents |
|---|---|
| `qe-agent-usage.json` | Token counts (input, output, cache), USD cost, turn count, and wall-clock duration. |
| `qe-agent-commands.log` | Every tool call Claude made (Bash commands, Read/Write file paths, Grep/Glob patterns) — the invocation strings only, not their output. Bash command strings may reference sensitive paths (e.g. KUBECONFIG, mounted secrets). Treat this log with the same access controls as other CI artifacts. |

The full stream-json session output (which includes cluster logs, API responses, and `--verbose` traces) is captured to a temporary file in the pod and deleted on exit — it never reaches the CI build-log or GCS. Only these two derived files are written to `ARTIFACT_DIR`. Note: while cluster data (pod logs, API responses) is excluded, command strings and file paths in the audit log may reference sensitive locations.

### Required: non-cloud provisioned clusters

This step **must not be used with cloud-provisioned clusters** (GCP, AWS, Azure, etc.) — the agent runs with cluster-admin privileges and could read cloud provider credentials stored in `kube-system`. Use non-cloud provisioned clusters where no cloud credentials are present.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `AGENT_SKILL` | — | Name of the skill to load from the `skills/` directory. Step is skipped if unset or the file does not exist. |
| `CLAUDE_MODEL` | `claude-opus-4-6` | Claude model used for analysis. |
| `CLAUDE_CODE_USE_VERTEX` | `1` | Enable Google Vertex AI backend for Claude Code. |
| `CLOUD_ML_REGION` | `global` | Google Cloud region for Vertex AI. |
| `ANTHROPIC_VERTEX_PROJECT_ID` | `itpc-gcp-hcm-pe-eng-claude` | GCP project ID for Vertex AI authentication. |
| `GOOGLE_APPLICATION_CREDENTIALS` | `/var/run/claude-code-service-account/claude-prow` | Path to the GCP service account key file. |

---

## Real-World Example — Distributed Tracing QE

The Distributed Tracing QE team (Tempo Operator, OpenTelemetry Operator, Tracing UI) was the first adopter of this step. Their upstream OCP 4.22 jobs use:

**CI config snippet** (`openshift-grafana-tempo-operator-main__upstream-ocp-4.22-amd64.yaml`):
```yaml
env:
  AGENT_SKILL: TEMPO
post:
- ref: openshift-observability-qe-agent
- chain: <deprovision-chain>
```

**Test step trap** (in `distributed-tracing-tests-tempo-upstream-commands.sh`):
```bash
function notify_qe_agent() {
    local has_failures=false
    grep -rqE '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true

    local i=0
    while IFS= read -r xml; do
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "step_script_ref": "distributed-tracing/tests/tempo/upstream/distributed-tracing-tests-tempo-upstream-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {}
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT
```

---

## Capabilities and Tool Inventory (GLC-08)

### Tools accessible to the agent

| Capability | Tool/API | Access Level | Guardrail |
|---|---|---|---|
| Shell commands | `Bash` (Claude Code) | Full pod OS (non-root) | `--allowedTools` allowlist; no WebFetch/WebSearch |
| File reading | `Read` (Claude Code) | Any pod-visible file | Skill scopes to SHARED_DIR, ARTIFACT_DIR, test repos |
| File writing | `Write` (Claude Code) | Any pod-writable path | Skill scopes to ARTIFACT_DIR/test-fixes/ |
| Pattern search | `Grep`, `Glob` (Claude Code) | Pod filesystem | Read-only |
| Cluster API | `oc`/`kubectl` via Bash | cluster-admin RBAC | Non-cloud clusters only; no cloud credentials present |
| AI model | Claude (Vertex AI) | API call via service account | `--max-budget-usd 5`; scoped GCP SA |
| Git (read-only) | `git clone` via Bash | Public GitHub repos | No git credentials mounted; no push capability |

### Authorized actions

- Read test artifacts (JUnit XMLs, context files) from `SHARED_DIR`
- Rerun specific failing tests using framework CLIs (chainsaw, cypress)
- Read cluster state (pods, logs, events, CRDs, operator status)
- Write analysis output to `ARTIFACT_DIR` (uploaded to GCS for human review)
- Write proposed test fixes to `ARTIFACT_DIR/test-fixes/`
- Clone public GitHub repositories for test environment setup

### Prohibited actions

- Push git changes (no git credentials mounted)
- Access cloud provider credentials (**deployment prerequisite**: non-cloud clusters only — see [Cluster requirement](#cluster-requirement-non-cloud-provisioned-clusters-only))
- Make outbound HTTP requests via Claude tools (`WebFetch`/`WebSearch` not in `--allowedTools`). Note: the `Bash` tool can still invoke `curl`/`wget` if instructed by the skill; outbound egress depends on pod network policy, which is a **deployment prerequisite** — not enforced by this step
- Modify production infrastructure (ephemeral test cluster only)
- Access other teams' clusters or namespaces
- Create or modify Jira tickets, PRs, or any external resources
- Install software outside the pod (no root access)

### Guardrails for write/execute actions

| Action | Guardrail | Enforcement Level |
|---|---|---|
| Bash command execution | `--allowedTools` allowlist | Protocol-enforced (Claude Code runtime) |
| File writes | Skill-scoped to `ARTIFACT_DIR`; post-processing adds AI-generated banner | Prompt-level (skill instructions) |
| Cluster mutations (create/delete/patch) | Ephemeral test cluster; deprovision chain destroys cluster after run | Infrastructure-level (CI job lifecycle) |
| API spend | `--max-budget-usd 5` hard cap | Protocol-enforced (Claude Code runtime) |
| Session duration | `timeout: 1h30m0s` | Infrastructure-enforced (ci-operator) |
| Non-cloud cluster requirement | No cloud credentials in cluster | **Deployment prerequisite** — CI config must use non-cloud `cluster_profile` |
| Network egress | Pod-level network policy | **Deployment prerequisite** — not enforced by this step |

---

## Human-in-the-Loop (HITL) and Accountability (HU-02)

### Workflow

The agent operates autonomously during execution but all output requires human review before action:

1. **Agent produces output** — analysis summaries, bug reports, and proposed test fixes are written as files to `ARTIFACT_DIR`
2. **Files uploaded to GCS** — the CI sidecar uploads all artifacts to GCS, accessible via the Prow job URL
3. **Human reviews output** — an engineer reads `qe-agent-analysis.md` and validates the diagnosis
4. **Human takes action** — if the agent proposed a test fix, the engineer reviews the diff in `test-fixes/`, verifies it, and submits a PR. If the agent wrote a bug report, the engineer reviews `bug-report.md` and files a Jira issue manually

The agent **never**:
- Pushes code or creates PRs
- Files Jira bugs or comments on issues
- Sends notifications (Slack, email)
- Modifies any system outside the ephemeral test cluster and `ARTIFACT_DIR`

All AI-generated output includes a persistent disclaimer: **"Always review AI-generated output prior to use."**

### Re-authorization triggers (HU-02)

The following non-bypassable controls force the agent to halt:

| Trigger | Mechanism | Threshold |
|---|---|---|
| Budget ceiling | `--max-budget-usd 5` | Claude halts when API spend reaches $5 |
| Time expiration | `timeout: 1h30m0s` | ci-operator kills the pod after 90 minutes |
| Scope enforcement | `--allowedTools "Bash,Read,Write,Grep,Glob"` | Tool calls outside this set are rejected at the protocol level |
| Skill size limit | `wc -c` check in commands script | Skills exceeding 100KB are rejected |
| Input validation | Regex check on `AGENT_SKILL` | Names not matching `^[A-Za-z0-9_-]+$` are rejected |

**Approved tooling**: Claude Code CLI is the enterprise-approved orchestration tool. The `--allowedTools` allowlist replaces the standard permission system as the enforcement boundary (the step uses `--dangerously-skip-permissions` because it runs non-interactively, but `--allowedTools` provides protocol-level scope enforcement).

### Emergency stop / Kill switch (HU-02)

Multiple independent mechanisms can immediately terminate the agent:

1. **Cancel the Prow job** — immediately terminates the pod, including the Claude session. Available to any engineer with Prow access via the job UI or `oc delete pod`.
2. **Step timeout** — `timeout: 1h30m0s` enforced by ci-operator; non-bypassable by the agent. Kills the pod if exceeded.
3. **Budget kill** — `--max-budget-usd 5` stops Claude when API spend reaches $5. Enforced by Claude Code runtime, independent of the agent's logic.
4. **Grace period** — `grace_period: 2m0s` allows the EXIT trap to clean up temporary files after timeout.
5. **`best_effort: true`** — even if the agent crashes or is killed, the CI pipeline continues to the deprovision step. The agent cannot block the pipeline.
6. **Cluster destruction** — the deprovision chain runs after the agent, destroying the entire test cluster regardless of agent behavior. Any cluster-level changes the agent made are eliminated.

All mechanisms function independently of the agent's logic and the AI model.

### Rollback

- **Cluster changes**: No rollback needed — the deprovision chain destroys the cluster.
- **ARTIFACT_DIR files**: Files uploaded to GCS are read-only artifacts. They do not trigger automated actions. If an analysis is incorrect, the engineer simply ignores it.
- **Test fixes**: Proposed fixes in `test-fixes/` are files in GCS, not applied to any repository. A human must create a PR to apply them.

---

## Policy Enforcement and Runtime Guardrails (TG-03)

### Enforcement layer

```text
┌─────────────────────────────────────────────────┐
│ ci-operator                                      │
│  └── timeout: 1h30m0s (kills pod)               │
│       └── Claude Code CLI                        │
│            ├── --allowedTools (protocol-level)   │
│            │    Only: Bash, Read, Write, Grep,   │
│            │    Glob                              │
│            │    Blocked: WebFetch, WebSearch,     │
│            │    Agent, all others                 │
│            ├── --max-budget-usd 5 (spend cap)    │
│            └── Skill system prompt (soft scope)  │
│                 └── AGENT_SKILL input validation │
│                      └── ^[A-Za-z0-9_-]+$ regex  │
└─────────────────────────────────────────────────┘
```

- **`--allowedTools`**: Protocol-level enforcement — tool calls not in the allowlist are rejected before execution. This is the primary scope enforcement mechanism.
- **`--max-budget-usd 5`**: Hard spend cap enforced by Claude Code runtime. The agent cannot override this.
- **Step timeout**: ci-operator enforces `timeout: 1h30m0s` — kills the pod if exceeded. Independent of Claude.
- **`best_effort: true`**: Agent failures do not block the CI pipeline.
- **Skill-level instructions**: System prompt scopes what the agent _should_ do. This is a prompt-level control (not technical enforcement).
- **Input validation**: `AGENT_SKILL` validated against `^[A-Za-z0-9_-]+$`; skill fetch uses `--max-redirs 0` to prevent redirect-based bypass; skill size capped at 100KB.

---

## Access Scope and Boundary Validation (TG-04)

### Operational boundaries

| Boundary | Enforcement | Validation |
|---|---|---|
| **Filesystem** | Pod filesystem (non-root). Agent can read/write any pod-accessible path. | No exfiltration path: no WebFetch, no git push, no outbound HTTP. Sensitive files (KUBECONFIG, secrets) are readable but cannot be sent externally. |
| **Cluster** | cluster-admin RBAC on the ephemeral test cluster only. | No other clusters are reachable. Non-cloud clusters have no cloud provider credentials. |
| **Network** | `--allowedTools` blocks WebFetch/WebSearch. | Git clone from public GitHub repos only. Vertex AI API via service account. No arbitrary outbound HTTP. |
| **AI API** | Vertex AI via scoped GCP service account. | Service account has Vertex AI API access only. `--max-budget-usd 5` caps spend. |
| **Input** | `AGENT_SKILL` regex validation. Skill fetch with `--max-redirs 0`. | Path traversal prevented. Redirect bypass prevented. 100KB size limit. |

### Modular capabilities — Dynamic least privilege (TG-04)

The skill system implements dynamic least privilege:

- Only the skill matching `AGENT_SKILL` is loaded as the system prompt — the agent never sees other skills
- Each skill targets a specific operator/component with specific test commands and diagnostic procedures
- The agent's context window contains only task-relevant instructions
- `--allowedTools "Bash,Read,Write,Grep,Glob"` presents 5 of Claude Code's ~20+ total tool capabilities

---

## RBAC and Credential Management (TG-01)

### Credentials

| Credential | Scope | Lifecycle |
|---|---|---|
| GCP service account (`claude-prow`) | Vertex AI API access only | Mounted read-only at `/var/run/claude-code-service-account/`; destroyed with pod |
| `KUBECONFIG` | cluster-admin on ephemeral test cluster | Inherited from CI job; cluster destroyed after job |
| GitHub (public repos) | Read-only (unauthenticated `git clone`) | No credentials mounted; no push capability |

### Least privilege enforcement

- **Tool allowlist**: Claude restricted to 5 tools via `--allowedTools`
- **No persistent credentials**: All credentials are pod-scoped and destroyed when the pod terminates
- **No cloud provider credentials**: Non-cloud clusters only — no GCP/AWS/Azure credentials in the cluster
- **Service account scoping**: GCP SA has Vertex AI API access only; no other GCP services are accessible
- **No admin actions**: The agent cannot merge code, approve PRs, modify repository security settings, or access admin APIs

---

## Immutable Audit Logging (TG-08)

### Audit artifacts

Every agent run produces two audit files in `ARTIFACT_DIR`:

| File | Contents | Format |
|---|---|---|
| `qe-agent-usage.json` | Token counts (input, output, cache), USD cost, turn count, wall-clock duration | JSON (single line) |
| `qe-agent-commands.log` | Every tool call: `[Bash]` commands, `[Read]`/`[Write]` file paths, `[Grep]`/`[Glob]` patterns. Bash command strings may reference sensitive paths. | Text with `[Tool]` headers |

### Immutability

- Files are written to `ARTIFACT_DIR` in the pod
- The CI sidecar uploads them to GCS after the step completes
- GCS objects are immutable once uploaded (Prow does not overwrite artifacts)
- The full stream-json session (which contains cluster data) is captured to a temp file and **deleted on exit** — it never reaches GCS

### Audit trail contents

The `qe-agent-commands.log` records the complete lifecycle:
- Every shell command executed (`[Bash]`)
- Every file read (`[Read]`) and written (`[Write]`)
- Every pattern search (`[Grep]`, `[Glob]`)

This enables post-incident review of what the agent did, without exposing cluster data (pod logs, API responses). Note: Bash command strings may reference sensitive paths (e.g. KUBECONFIG, mounted secrets) — treat the audit log with the same access controls as other CI artifacts.

**Enterprise tooling**: Claude Code CLI with Vertex AI backend; GCS artifact storage via Prow CI sidecar.

---

## Safety / HAP Controls (TG-09)

- **Built-in model safety**: Claude models include built-in content safety filters (Anthropic's usage policies) that block hateful, abusive, and profane content generation
- **Technical focus**: The agent's system prompt (skill) focuses it exclusively on technical QE tasks — JUnit XML parsing, operator diagnostics, test code analysis. No user-facing content generation.
- **Output domain**: All output is technical (test analysis, operator logs, YAML diffs, bug reports). The risk of HAP content in this domain is minimal.
- **Production status**: Controls are active via the Claude API/Vertex AI layer. No additional HAP filtering is required.

---

## ESS Compliance (TG-06)

The agent aligns with Red Hat's Enterprise Security Standard:

- **No PII expected in inputs**: Agent inputs are CI test artifacts (JUnit XMLs, operator logs, test code) that are not expected to contain personal information. However, pod-visible logs and cluster state are not explicitly redacted before ingestion — if PII is present in CI artifacts (e.g. usernames in cluster events), the agent may process it. Skill authors should avoid instructing the agent to access data outside standard CI artifacts.
- **Short-lived credentials**: All credentials (GCP SA, KUBECONFIG) are pod-scoped and destroyed when the pod terminates.
- **Network access restricted**: No outbound HTTP beyond Vertex AI API and public GitHub. `--allowedTools` blocks WebFetch/WebSearch at the protocol level.
- **Audit logging enabled**: Every tool call is logged to `qe-agent-commands.log`; cost/usage tracked in `qe-agent-usage.json`.
- **Ephemeral environment**: The test cluster and pod are destroyed after each CI job.

For ESS-specific guidance, contact `#talk-to-grc` on Red Hat Slack (`grc@redhat.com`).

---

## Dataflow Diagram (DATA-02)

```text
CI Job Pod (ephemeral)
┌─────────────────────────────────────────────────────────┐
│ Test Step                                                │
│  - Runs e2e tests -> JUnit XMLs in ARTIFACT_DIR         │
│  - EXIT trap writes:                                     │
│    - qe-agent-context.json -> SHARED_DIR                │
│    - qe-agent-junit-*.xml  -> SHARED_DIR                │
└──────────────────────┬──────────────────────────────────┘
                       │ SHARED_DIR (flat files, K8s Secret)
                       v
┌─────────────────────────────────────────────────────────┐
│ QE Agent Post-Step (this step)                           │
│                                                          │
│  Inputs:                                                 │
│  ├── SHARED_DIR/qe-agent-context.json                   │
│  ├── SHARED_DIR/qe-agent-junit-*.xml                    │
│  └── Skill file (fetched from GitHub main branch)       │
│                                                          │
│  Processing:                                             │
│  ├── Claude Code CLI (--print, non-interactive)         │
│  │   ├── System prompt: skill content                   │
│  │   ├── Tools: Bash, Read, Write, Grep, Glob           │
│  │   ├── Cluster: oc/kubectl via KUBECONFIG             │
│  │   └── AI API: Vertex AI (GCP SA, $5 budget cap)     │
│  └── Post-processing: AI-generated banners, audit log   │
│                                                          │
│  Outputs (ARTIFACT_DIR):                                 │
│  ├── qe-agent-analysis.md    (analysis summary)         │
│  ├── qe-agent-usage.json     (cost/token audit)         │
│  ├── qe-agent-commands.log   (tool call audit)          │
│  ├── bug-report.md           (if PRODUCT_BUG)           │
│  ├── test-fixes/CHANGES.md   (if TEST_ISSUE/FLAKY)     │
│  ├── test-fixes/<files>      (proposed test fixes)      │
│  └── cluster-instability-report.md (if applicable)      │
│                                                          │
│  Temp data (deleted on exit):                            │
│  └── stream-json session file (mktemp, rm via trap)     │
└──────────────────────┬──────────────────────────────────┘
                       │ ARTIFACT_DIR
                       v
┌─────────────────────────────────────────────────────────┐
│ GCS Artifact Upload (CI Sidecar)                         │
│  - Immutable storage                                    │
│  - Accessible via Prow job URL                          │
│  - Subject to GCS lifecycle policies                    │
└──────────────────────┬──────────────────────────────────┘
                       │
                       v
              Human Review
              (engineer reads analysis, validates diagnosis,
               files Jira bugs, submits test fix PRs)
```

**External data flows**:
- **Vertex AI API** (outbound): Claude Code CLI sends prompts and receives completions via the GCP service account. Stateless — no conversation persistence on the provider side.
- **GitHub raw content** (outbound): Skill file fetched from `raw.githubusercontent.com`. Read-only, unauthenticated.
- **GitHub repos** (outbound): Test repositories cloned via `git clone`. Read-only, unauthenticated.

---

## Data Handling and Purge/Deletion (DATA-05)

### Data handling notice

Do not add unapproved personal information or customer data to skill files, `qe-agent-context.json`, or any input to this agent. Refer to the Enterprise AI Risk Management Standard for types of personal information and customer data that are out of scope.

### Zero-persistence architecture

| Data | Storage Location | Lifecycle | Deletion |
|---|---|---|---|
| Stream-json session output | Pod temp file (`mktemp`) | Duration of agent run | Deleted via `trap 'rm -f ...' EXIT` — never reaches GCS |
| Pod filesystem (all data) | Ephemeral pod storage | Duration of CI job | Destroyed when pod terminates |
| Test cluster (all state) | Ephemeral cluster nodes | Duration of CI job | Destroyed by deprovision chain after agent runs |
| ARTIFACT_DIR files | GCS (via CI sidecar) | Subject to GCS lifecycle policies | Managed by Prow/GCS retention policies |
| Vertex AI API calls | Stateless API | Request/response only | No conversation persistence on provider side |
| Skill file (fetched) | Pod memory (shell variable) | Duration of agent run | Destroyed with pod |

No data is cached or stored on local machines. The agent runs exclusively in CI infrastructure.

---

## Continuous Monitoring (Mon-01)

### Runtime integrity monitoring

1. **Cost and usage tracking**: `qe-agent-usage.json` records token counts, USD cost, turns, and duration per run. Aggregate across runs to detect anomalies (unusually high cost, excessive turn counts, prolonged duration).
2. **Tool call audit**: `qe-agent-commands.log` records every tool invocation. Post-incident review compares executed commands against skill instructions to detect scope creep or unexpected actions.
3. **Behavioral drift**: Compare agent outputs across runs for the same failure type. Degradation in diagnosis quality or changes in command patterns may indicate prompt drift or model updates.

### Feedback and quality sampling

4. **Per-run feedback**: The "Skill Improvement Recommendations" section in each `qe-agent-analysis.md` captures deviations from skill steps — commands that failed, missing diagnostics, steps that needed adaptation. This feeds directly into skill refinement.
5. **Failure rate**: Track how often the agent exits without producing `qe-agent-analysis.md` (incomplete analysis) or without producing any output at all.
6. **Accuracy spot-checks**: Periodically sample `qe-agent-analysis.md` outputs and manually verify the diagnosis against the actual test failure and cluster state.
7. **Tool invocation audit**: Review `qe-agent-commands.log` entries. Flag if the agent used `Write` when `Read` was sufficient, or executed cluster-mutating commands not prescribed by the skill.

### Data integrity

8. **Stale data detection**: Skills include version-specific references (operator namespaces, CRD names, image tags). When these change between releases, the agent may produce incorrect diagnostics. Monitor for increased failure rates after release branch cuts.

### Performance tracking

9. **Helpfulness rate**: Track how often the agent's diagnosis is actionable — measured by whether the engineer filed a bug or submitted a test fix PR based on the agent's output.
10. **Quality indicators**: Watch for repetitive or shallow analyses that suggest the model is struggling with prompt complexity.
11. **Cost efficiency**: Track average cost per run and cost per actionable finding.

### Anomaly detection

12. **Budget exhaustion**: Monitor how often the `--max-budget-usd 5` cap is hit (indicates the agent needed more budget, or entered a loop).
13. **Timeout hits**: Monitor how often the 90-minute timeout fires (indicates runaway sessions).
14. **Excessive tool calls**: Alert on runs with significantly more tool invocations than the skill prescribes.

### Review cadence

**Quarterly**: Review aggregated usage data, command audit logs, user feedback, and accuracy spot-check results. Update skills based on findings. Adjust budget/timeout thresholds if needed.

---

## Feedback Mechanism (FBK-01)

### Providing feedback

Report agent quality, accuracy, or behavioral issues via the **TRACING Jira project** using the `ai-agent-feedback` label:

- **What to report**: Incorrect diagnoses, missed root causes, unhelpful analysis, unexpected agent behavior, skill improvement suggestions
- **What to include**: Link to the Prow job run, the `qe-agent-analysis.md` output, and a description of what was wrong or could be improved
- **Access**: Feedback is visible to the TRACING project team members with a justified business purpose

### Built-in feedback

Each `qe-agent-analysis.md` includes a "Skill Improvement Recommendations" section where the agent self-reports deviations from skill steps. This per-run feedback is reviewed during quarterly monitoring cycles and used to refine skill instructions.

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| "Skipping qe-agent" (no context file) | Test step did not set up the `notify_qe_agent` EXIT trap | Add the EXIT trap to your test step script (see [Setup](#setup) step 3) |
| "Failed to fetch skill" | `AGENT_SKILL` typo or skill file not merged to main | Verify the skill name matches a file in `skills/` on the main branch |
| "AGENT_SKILL contains invalid characters" | Skill name has special characters | Use only alphanumeric, hyphens, and underscores |
| Agent output incomplete (budget hit) | Complex multi-failure scenario exceeded $5 | Reduce flakiness rerun count in skill, or increase `--max-budget-usd` |
| Agent output incomplete (timeout) | Analysis took longer than 90 minutes | Simplify the skill steps or increase `timeout` in the ref YAML |
| "Claude Code CLI not found" | CLI not installed in the test runner image | Add CLI installation to your Dockerfile (see [Setup](#setup) step 2) |
| MCP timeout in Step 0a | Cluster instability; nodes updating | Rerun the CI job. If persistent, check MachineConfig changes in the test step |
| All tests pass but agent still ran | `has_test_failures` incorrectly set to `true` | Check the `notify_qe_agent` grep pattern matches your JUnit XML format |

---

## Point of Contact

For questions about this step, skill development, or agent behavior:

**Team**: Red Hat OpenShift Distributed Tracing QE
**Email**: `tracing-team@redhat.com`
**Step OWNERS**: See `OWNERS` file in this directory

---

## Control Requirements Traceability

This section maps Enterprise AI Risk Management Standard control IDs to their implementations.

| Control ID | Control Name | Implementation |
|---|---|---|
| TR-01 | AI-generated tagging | AI-generated banner prepended to all `.md` output files by commands script; also embedded in skill output templates |
| TR-02 | User guide | This README document |
| TR-08 | Explainability of AI reasoning | Evidence Sources section in analysis summary; Diagnosis section cites specific logs, errors, and cluster state |
| HU-01 | In-app disclaimer | "Always review AI-generated output prior to use" in every output file banner |
| HU-02 | Re-authorization triggers | Budget ceiling ($5), timeout (90m), `--allowedTools` scope enforcement |
| HU-02 | Dynamic HITL oversight | All output requires human review; agent never pushes code or files bugs |
| HU-02 | Emergency stop / Kill switch | Cancel Prow job, step timeout, budget kill, cluster destruction |
| FBK-01 | Feedback mechanism | TRACING Jira project with `ai-agent-feedback` label |
| Mon-01 | Continuous monitoring | Usage/cost tracking, audit logs, quarterly review cadence |
| GLC-08 | Capabilities inventory | Capabilities and Tool Inventory section |
| TG-01 | RBAC and credentials | RBAC and Credential Management section; scoped GCP SA, ephemeral KUBECONFIG |
| TG-03 | Policy enforcement | `--allowedTools` protocol-level enforcement, budget cap, timeout |
| TG-04 | Access scope and boundaries | Non-cloud clusters, no WebFetch, no git push, input validation |
| TG-04 | Modular capabilities | Skill-based dynamic least privilege; 5-tool allowlist |
| TG-08 | Immutable audit logging | `qe-agent-usage.json` + `qe-agent-commands.log` -> GCS (immutable) |
| TG-09 | HAP controls | Claude built-in safety filters; technical-only output domain |
| TG-06 | ESS compliance | No PII, short-lived credentials, restricted network, audit logging |
| DATA-02 | Dataflow diagram | Dataflow Diagram section |
| DATA-05 | Purge/deletion | Zero-persistence architecture; temp files deleted via EXIT trap |
