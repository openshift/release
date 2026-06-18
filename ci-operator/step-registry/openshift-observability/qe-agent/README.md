# openshift-observability-qe-agent

Agentic post-step for OpenShift Observability teams that autonomously triages e2e test failures using Claude Code CLI.

When a test step reports failures, the agent reads the JUnit XML reports and a context file from `SHARED_DIR`, then runs Claude with a team-provided skill to diagnose the root cause and — depending on the skill — attempt remediation (re-run failing tests, propose a fix, write a bug report, etc.).

The step is a **no-op** (exits immediately with no cost) when:
- `AGENT_SKILL_URL` is not set
- `SHARED_DIR/qe-agent-context.json` is absent (test step did not run or skipped the trap)
- `has_test_failures` in the context file is `false` (all tests passed)

Full Claude output is streamed to CI logs in real-time and saved to `ARTIFACT_DIR/qe-agent-output.json` for post-run inspection.

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

### 4. Add the step and set `AGENT_SKILL_URL` in your CI config

Add `openshift-observability-qe-agent` to the `post:` phase of your test and set `AGENT_SKILL_URL` in the `env:` block of the same test to the raw URL of your team's `SKILL.md`:

```yaml
tests:
- as: my-upstream-tests
  steps:
    cluster_profile: <profile>
    env:
      AGENT_SKILL_URL: https://raw.githubusercontent.com/openshift/<your-repo>/main/plugins/qe-agent/skills/SKILL.md
      # ... other env vars
    post:
    - ref: openshift-observability-qe-agent
    - chain: <your-deprovision-chain>
    test:
    - ref: <your-test-ref>
```

---

## Agent Skill

The skill is a `SKILL.md` Markdown file hosted in your team's QE repository. It is fetched at runtime by the step and passed to Claude as the system prompt. The skill defines how Claude should approach the failure: what tests to re-run, what logs to collect, how to classify the root cause, and what output to produce.

See the [Distributed Tracing QE skill](https://github.com/openshift/distributed-tracing-qe/blob/main/plugins/qe-agent/skills/SKILL.md) as a reference implementation.

### AGENT_SKILL_URL

| Property | Value |
|---|---|
| Required | Yes |
| Allowlist | Must start with `https://raw.githubusercontent.com/openshift/` — any other URL is rejected at runtime |
| Example | `https://raw.githubusercontent.com/openshift/distributed-tracing-qe/main/plugins/qe-agent/skills/SKILL.md` |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `AGENT_SKILL_URL` | — | Raw URL to the team's `SKILL.md`. Must start with `https://raw.githubusercontent.com/openshift/`. Step is skipped if unset or URL fails the allowlist check. |
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
  AGENT_SKILL_URL: https://raw.githubusercontent.com/openshift/distributed-tracing-qe/main/plugins/qe-agent/skills/SKILL.md
post:
- ref: openshift-observability-qe-agent
- chain: cucushift-installer-rehearse-azure-ipi-deprovision
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
