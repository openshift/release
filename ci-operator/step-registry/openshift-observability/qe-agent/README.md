# openshift-observability-qe-agent

Agentic post-step for OpenShift Observability teams that autonomously triages e2e test failures using Claude Code CLI.

When a test step reports failures, the agent reads the JUnit XML reports and a context file from `SHARED_DIR`, then runs Claude with a team-provided skill to diagnose the root cause and — depending on the skill — attempt remediation (re-run failing tests, propose a fix, write a bug report, etc.).

The step is a **no-op** (exits immediately with no cost) when:
- `AGENT_SKILL` is not set
- `SHARED_DIR/qe-agent-context.json` is absent (test step did not run or skipped the trap)
- `has_test_failures` in the context file is `false` (all tests passed)

Claude's full session output (stream-json) is captured to a temporary file and never written to the CI build-log or uploaded to GCS. Two derived artifacts are extracted from it and saved to `ARTIFACT_DIR` after the session completes: a cost/usage record and a Bash command audit log (see [Audit artifacts](#audit-artifacts)).

---

## Why use this step

The traditional workflow for debugging a CI test failure is:

1. Provision a new cluster (~30–45 minutes)
2. Set up the test environment (operators, dependencies, configuration)
3. Run the failing test suite
4. Inspect logs and iterate

End-to-end this typically takes **1–2 hours of cluster time**, which at OpenShift CI cloud rates is substantially more expensive than the AI API cost — and requires an engineer's attention throughout.

The qe-agent step runs **inside the already-provisioned CI job**, against the cluster that just ran the tests. The environment is already set up. The failing test artifacts are already present. Claude reruns the exact failing tests, collects diagnostics, and produces a root-cause analysis and proposed fix — all autonomously, at a cost of **$3–5 in AI API spend** per run based on observed production runs.

The cost can be reduced further by:
- Implementing cross-run pattern awareness using Sippy to skip analysis for known failures
- Reducing the rerun count in the flakiness confirmation loop
- Switching to a smaller model for simpler triage tasks

Even at the current ceiling of $5, a single qe-agent run replaces most of the value of a 1–2 hour manual debug session on a freshly provisioned cluster.

> **Where to add this step**: Target upstream testing CI jobs first, not the full job matrix. Upstream jobs run against the latest operator and test code, so they surface both product regressions and test issues at the earliest point in the development cycle — exactly where autonomous triage adds the most value. Adding the step to every job (stage, product, multi-arch, disconnected) spreads AI budget across runs where failures are often already understood, and increases noise before the step has proven itself in your environment. Until cross-run pattern awareness via Sippy is implemented — preventing the agent from running against failures that are already known and tracked — keep the step limited to upstream jobs where each failure is more likely to be novel and worth investigating.

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
├── OTEL.md          ← OpenTelemetry Operator (junit_otel_* tests, chainsaw)
├── TEMPO.md         ← Tempo Operator (junit_tempo_* tests, chainsaw)
├── TRACING_UI.md    ← Distributed Tracing Console Plugin (Cypress)
├── DISCONNECTED.md  ← Distributed Tracing disconnected suite (chainsaw)
└── OWNERS
```

Each skill is fetched at runtime from `https://raw.githubusercontent.com/openshift/release/main/...` and passed to Claude as its system prompt. The skill defines how Claude should approach the failure: what tests to re-run, what logs to collect, how to classify the root cause, and what output to produce.

### Adding a new team skill

1. Create `ci-operator/step-registry/openshift-observability/qe-agent/skills/<TEAM_NAME>.md`
2. Add your team identifier to the `OWNERS` file in `skills/`
3. Open a PR to `openshift/release` — the step OWNERS review and approve it
4. Set `AGENT_SKILL: <TEAM_NAME>` in your CI config

Skill names must be alphanumeric (hyphens and underscores allowed). The step rejects any value that does not match `^[A-Za-z0-9_-]+$` to prevent path traversal.

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
| `qe-agent-commands.log` | Every Bash command Claude executed — the command strings only, not their output. Cluster data (pod logs, events, API responses) is deliberately excluded. |

The full stream-json session output (which includes cluster logs, API responses, and `--verbose` traces) is captured to a temporary file in the pod and deleted on exit — it never reaches the CI build-log or GCS. Only these two derived files, which contain no cluster data, are written to `ARTIFACT_DIR`.

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
