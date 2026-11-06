# Agentic PR validation

`openshift-agentic-prepare-validation` captures the intended behavior of one PR
and writes a checked plan. `openshift-agentic-validate` runs that plan against the
workflow's disposable cluster and publishes evidence, results, Markdown and JUnit.

The production Python runner lives beside this file. Its supervisor and relay
entrypoints share the registry component so rehearsal discovery resolves them
to the existing reference.
Both registry steps are owned by test platform through the `dptp` owner alias.

## Prebuilt runner image

`clusters/app.ci/supplemental-ci-images/agentic-validation.yaml` defines the
`ci/agentic-validation` BuildConfig on app.ci. Argo CD manages it with the other
supplemental CI images. Its initial ConfigChange trigger builds the runner from
`main` and publishes `quay.io/openshift/ci:ci_agentic-validation_latest` using the
existing image-mirror push secret. Consumers use the `ci/agentic-validation:latest`
base-image alias.

There are no image-build or image-promotion Prow jobs for this runner. The image
is built before component jobs use it. After changing the Python helpers, rebuild
it explicitly and wait for the build to finish:

```sh
oc --context=app.ci -n ci start-build agentic-validation --follow --wait
```

The BuildConfig installs Python 3.12, bash and Git on the existing nested-podman
image and copies `oc` from the CLI image. It copies only the production helpers.
The command container runs by the immutable local image ID resolved by its
supervisor.

## Preparation

1. `tested_pull_request` validates the repository, PR number and tested SHAs from
   `JOB_SPEC`. `capture_pull_request` fetches its title, description and exact diff.
2. `capture_issue` reads each linked issue's summary and description from
   `https://redhat.atlassian.net`. Validation instructions and acceptance criteria
   are read from that text. A retrieval failure is recorded and PR fallback is
   attempted; an overall deadline remains fatal.
3. `generate_plan` asks the model for focused checks, attaches trusted source
   metadata, validates every check, and computes the plan hash.
4. `write_plan` writes `validation.json`, `validation.md` and public source
   references to SHARED_DIR and the artifact directory. Private source bodies and
   unchecked model-supplied gaps are not published.

Plans describe issue requirements, so source issues must be suitable for public
CI artifacts even though the raw issue bodies are not published.

Jira requirements take precedence over PR inferences. Each check identifies its
requirement source, prerequisites, actions, expected observation and evidence.
Empty plans, ambiguous scope and incomplete issue coverage stop preparation.

## Execution and reporting

1. `load_plan` checks the hash, rendered Markdown and job revision.
2. `prepare_cluster` flattens the target kubeconfig and verifies that a ready
   container runs the tested payload component digest.
3. `Execution.run_command` runs a bounded command in the sandbox and records its
   sanitized output. `Execution.record_result` accepts one immutable outcome per
   check and verifies that its referenced evidence exists and belongs to it.
4. `finalize` fills in unexecuted checks and writes JSON, Markdown and JUnit from
   the same outcomes. Product failures take precedence over unfinished checks.
   Only complete passing checks without a runner error produce exit code zero.

The execution agent does not fetch more issues or change the implementation.
Results are pass, fail or unable to verify; reports describe the limits of the
observations, including requirements inferred without Jira.

## Job settings and limits

The configurable inputs are model endpoint and model IDs, credential locations,
the payload component to verify, the execution turn limit and the overall deadline.
Jira's origin is fixed. There is no custom acceptance-field setting or token-budget
setting. Model requests have fixed implementation limits of 512 KiB input and
4096 output tokens. Metrics retain service-reported token usage.

Both steps default to `granite-3.3-8b-instruct`. On 2026-11-11 the production
client passed a live completion, native function call and function-result round
trip against the corporate endpoint with that model. The earlier Granite 3.1
default rejects a 4096-token response allowance because its entire context is
4096 tokens. The credential is provisioned as
`test-platform-infra/agent-validation-model/token`.

`VALIDATION_TIMEOUT_SECONDS` is measured in **seconds**:

| Phase | Default | Meaning |
|---|---:|---|
| Prepare | 600 | 10 minutes, including source retrieval |
| Execute | 2700 | 45 minutes for the complete execution |
| Each sandbox command | 90 | Fixed command deadline |

The registry step timeout leaves extra time for reporting and cleanup. The
execution agent has at most 40 model turns by default. Requests reject redirects
and non-HTTPS endpoints. Native Chat Completions function tools are required for
execution; a text-only answer cannot pass.

## Cluster and credential boundaries

Generated commands run in a networkless, read-only nested container with dropped
capabilities, no-new-privileges, resource limits, and bounded writable tmpfs mounts.
Only the target kubeconfig and API-broker Unix socket are mounted. The supervisor
retains model and registry credentials; preparation alone receives Jira credentials.
Registry authentication is passed explicitly to payload inspection and image pulls.
The broker permits CONNECT only to the assigned API's pre-resolved addresses.

The broker does not isolate workloads created through the cluster API. Before
adding a component job, provide and verify infrastructure-level egress restrictions
that also cover privileged and host-networked workloads. Ordinary IPI provisioning
and namespace NetworkPolicies do not establish that boundary. No component
validation job is enabled by this change. Keep normal gathering/destruction post
steps in the eventual workflow.

## Verification

Use temporary Prow rehearsals to check real PR/Jira preparation and live-model
execution with controlled passing and failing observations. Retain the reports,
command evidence and job links, then remove the rehearsal configuration.
Helper test files and permanent rehearsal jobs are not part of this component.

The corporate model's basic completion and tool protocol have been checked live.
Plan quality, production image publication and a known-broken/fixed scenario on
isolated disposable clusters still require a live rehearsal. Local fixtures
establish runner behavior, not product correctness or model quality.
