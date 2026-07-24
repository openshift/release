# openshift-mcp-server-mcpchecker-eval step registry

Reusable CI steps for running [mcpchecker](https://github.com/mcpchecker/mcpchecker)
evaluations against the [openshift-mcp-server](https://github.com/openshift/openshift-mcp-server)
on a live OCP cluster. Designed to support both pre-merge (presubmit) and scheduled
(periodic) workflows via env-var and eval-target parameterization.

## Structure

```
mcpchecker-eval/
├── openshift-mcp-server-mcpchecker-eval          # core eval step (shared)
├── vertex-setup/                                  # credential setup: Vertex AI
├── credentials-setup/                             # credential setup: model API key
├── vertex/                                        # chain: vertex-setup → eval
└── model-api/                                     # chain: credentials-setup → eval
```

## Design intent

All evaluation logic lives in the single **`openshift-mcp-server-mcpchecker-eval`** step,
parameterized entirely by environment variables. Credential sourcing is separated into
provider-specific **setup steps** that write exports to `${SHARED_DIR}/mcpchecker-creds.env`,
which the eval step sources at startup. This keeps the eval step provider-agnostic and
makes adding a new provider a matter of adding a new setup step and chain.

The two chains are:

| Chain | Credential source | Typical use |
|---|---|---|
| `openshift-mcp-server-mcpchecker-eval-vertex` | `ocp-mcp` secret (GCP service account) | Gemini or Anthropic via Vertex AI |
| `openshift-mcp-server-mcpchecker-eval-model-api` | `openai-token` secret | Any non-Vertex provider |

Agent, model, and judge selection are specified entirely within the in-repo eval config
pointed to by `EVAL_CONFIG`. The credential setup steps exist only to surface authentication
material (service account files, API keys) that the eval config's agent definition requires;
they do not drive model routing themselves.

Both chains run against a live OCP cluster provisioned by the `ipi-aws` workflow.
`kubectl` is unavailable in the CI image; the eval step symlinks `oc` (provided via
`cli: latest`) to satisfy eval setup scripts that call `kubectl`.

## Eval step parameters

All set via `steps.env` in the calling CI config:

| Variable | Default | Purpose |
|---|---|---|
| `EVAL_CONFIG` | `evals/openai-agent/eval.yaml` | Repo-relative path to the eval YAML |
| `EVAL_LABEL_SELECTOR` | `suite=core` | Label filter passed to `mcpchecker check` |
| `TOOLSETS` | `core,config` | MCP server toolsets to start |
| `TASK_PASS_RATE` | `0.0` | Minimum fraction of tasks that must pass (0.0 = no gate) |
| `ASSERTION_PASS_RATE` | `0.0` | Minimum fraction of assertions that must pass (0.0 = no gate) |
| `GOOGLE_CLOUD_LOCATION` | `` | Vertex AI region (e.g. `us-east5`); Vertex chain only |
| `GOOGLE_CLOUD_PROJECT` | `` | GCP project ID; Vertex chain only |
| `GEMINI_USE_VERTEX` | `` | Set to `"1"` for Google Gemini via Vertex AI |
| `ANTHROPIC_USE_VERTEX` | `` | Set to `"1"` for Anthropic Claude via Vertex AI |

Artifacts written to `${ARTIFACT_DIR}`: `mcpchecker-out.json` and `junit_mcpchecker.xml`.

## Usage

### Presubmit — Vertex AI provider (Gemini or Anthropic)

```yaml
- as: mcpchecker-eval-google
  optional: true
  steps:
    cluster_profile: openshift-org-aws
    env:
      EVAL_CONFIG: evals/core-eval-testing/builtin-google/eval-core.yaml
      EVAL_LABEL_SELECTOR: suite=core
      GEMINI_USE_VERTEX: "1"
      GOOGLE_CLOUD_LOCATION: us-east5
      GOOGLE_CLOUD_PROJECT: ocp-mcp-server-team
    test:
    - chain: openshift-mcp-server-mcpchecker-eval-vertex
    workflow: ipi-aws
```

Switch to Anthropic by setting `ANTHROPIC_USE_VERTEX: "1"` (and clearing `GEMINI_USE_VERTEX`)
and pointing `EVAL_CONFIG` at the Anthropic eval YAML. The chain is identical.

### Periodic — non-Vertex provider

```yaml
- as: periodic-mcpchecker-eval
  cron: 0 9 * * 1
  steps:
    cluster_profile: openshift-org-aws
    env:
      EVAL_CONFIG: evals/openai-agent/eval.yaml
      EVAL_LABEL_SELECTOR: suite=core
      TASK_PASS_RATE: "0.8"
      ASSERTION_PASS_RATE: "0.8"
    test:
    - chain: openshift-mcp-server-mcpchecker-eval-model-api
    workflow: ipi-aws
```

The agent, model, and judge are configured inside the eval YAML (`EVAL_CONFIG`). The
`openai-token` secret in the `test-credentials` namespace must contain whatever
authentication keys that eval config's agent definition requires.

### Adding a new provider

1. Create a new `<provider>-setup/` directory with a ref that mounts the relevant secret
   and appends exports to `${SHARED_DIR}/mcpchecker-creds.env`.
2. Create a `<provider>/` directory with a chain that runs your setup step followed by
   `openshift-mcp-server-mcpchecker-eval`.
3. Add an `OWNERS` file to both directories.
4. Run `make registry-metadata` to regenerate metadata.
