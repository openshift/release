# Agentic PR validation

The two registry references are `openshift-agentic-prepare-validation` and
`openshift-agentic-validate`. Their shell entry points invoke the Python standard
library helpers in this directory. No ci-tools or Prow behavior changes are needed.

Preparation reads one PR and the exact base/head revisions in `JOB_SPEC.refs`.
It extracts every Jira key from the title, reads each issue's summary, description
and optional acceptance field, and asks the configured model for focused checks.
Jira requirements take precedence; PR text and the tested diff supply missing
details. Unavailable Jira is recorded and PR fallback is explicit. Multiple issues
must all have checks. Empty checks, unresolved gaps, unknown requirement sources,
and contradictory/unready plans fail preparation. Source checkout is reused when
available; otherwise the helper fetches the two Git trees needed for the tested
diff. This initial fallback supports public GitHub repositories.

The supervisor renders the model's checked JSON into `validation.md`, attaches
trusted source references and revision, and hashes the canonical plan. Execution
verifies the hash, Markdown, repository, PR number, base and tested revision. It
resolves `VALIDATION_COMPONENT` in `release:latest` and checks that a ready target
container actually runs that digest before starting the agent. The workflow must
use `include_built_images: true` so that payload contains the PR's component.

The execution model receives the captured plan, command output, and two native
Chat Completions tools: `run_command` and `record_result`. A text-only response
without results is an error. Results cannot be overwritten. Pass and fail require
nonempty command evidence belonging to that check; unable-to-verify requires a
reason. The supervisor, rather than the model, produces the final report and JUnit.
Failure takes precedence over unfinished checks. Only complete passing results
without a runner error return zero. Setup, runtime, API and protocol errors remain
distinct from observed product failures.

## Configuration and deployment

`openshift-release-main__agentic-validation.yaml` builds and promotes
`ci/agentic-validation:latest` and a commit-specific tag. The image contains Python,
the helpers, `oc`, bash, Git and the existing nested-podman runtime. There are no
third-party Python packages or runtime runner downloads. The nested command
container uses the dependency's image resolved to an immutable local image ID.

Before running the optional job:

1. Build/promote the runner image. During a release rehearsal, override the
   component's `agentic-validation` base image to that rehearsal's runner image.
2. Create the `test-platform-infra/agent-validation-model` credential group with
   a `token` field. This is a new credential, not an existing provisioned secret.
   Confirm the step pod can reach the corporate model endpoint and that the
   selected preparation and execution models are available. The example Granite
   model is configurable and has **not** been verified against the corporate
   service here. Execution requires native function-tool support, rather than a
   successful text response. Use different models for the two phases if needed.
3. Ensure the existing `jira-token-dptp-bot` credential can read the relevant
   projects. Configure `JIRA_ACCEPTANCE_FIELD` when acceptance criteria live in a
   custom field. Jira retrieval failure produces an explicitly limited PR fallback.
4. Verify the disposable cluster's infrastructure egress boundaries described
   below, including workloads that have host networking or privileged access.
5. Run `/test e2e-aws-agentic-validation` on a suitable
   `openshift/cluster-kube-controller-manager-operator` PR. The job is optional and
   does not run automatically. The inherited IPI post steps gather and destroy
   the cluster. Nothing in this implementation sends PR or Jira comments.

For another component, define the `agentic-validation` base image alias, retain
an existing ephemeral-cluster workflow, and put the two references in its test
phase. Set `VALIDATION_COMPONENT` to the corresponding payload image name. The
workflow must supply `SHARED_DIR/kubeconfig` for the target cluster and a
`release:latest` payload containing the component built from the tested PR.

The reference YAMLs document model endpoint, models, credential paths, timeout,
turn, output-token and total-budget settings. The client rejects redirects and
non-HTTPS endpoints. Model input bytes are charged as a conservative upper bound
on input tokens, reserving the next request and full output allowance before
submission. This bounds requests even if the endpoint omits usage telemetry; it
is not a currency-denominated billing limit. Per-command output is bounded, each
command has a ninety-second timeout, and runtime/turn limits apply independently.

## Sandbox boundary

Generated commands run in a separate nested container with no network interface,
read-only root filesystem, dropped capabilities, no-new-privileges, and fixed
CPU, memory, process and tmpfs limits. Its only host mounts are an embedded target
kubeconfig and a Unix socket. It has no source checkout, artifact directory,
SHARED_DIR, model token, Jira/GitHub token, service account mount, provisioning
credentials or container-engine socket. The supervisor executes no model-supplied
command outside that container. Command output is captured privately and scrubbed
before being sent back to the model or written as evidence.
An empty tmpfs masks `/run/secrets`, including subscription mounts which Podman
can otherwise inject from the host's `mounts.conf`.

The nested container disables SELinux process labeling to connect to the
supervisor's Unix socket; the mount/network namespaces, capability restrictions,
default seccomp profile and resource limits still apply. The container smoke test
exercises this broker connection on an SELinux-enabled host.

A loopback relay forwards HTTP CONNECT requests through the Unix socket. The
broker permits only the exact target Kubernetes API authority and connects to
the addresses resolved when the sandbox starts. Other methods, hosts and ports
are rejected. The model service is used only by the trusted supervisor; the
command container cannot contact it. TERM, INT and the runtime alarm stop/remove
the whole command container, retain recorded results and write a failing report.
A command timeout also removes the whole container so detached processes cannot
outlive it. Build-cluster cleanup remains necessary after an uncatchable SIGKILL.

**The API broker does not isolate workloads created through that API.** The target
credential has cluster-admin power. An agent can create privileged/host-networked
workloads or tunnel through the API. Therefore use only a dedicated ephemeral
cluster whose infrastructure firewall/routing policy denies access to build-farm,
provisioning and unrelated internal networks, with explicit approved destinations.
Namespace NetworkPolicies alone do not establish that boundary. This must be
verified externally before the optional prototype job is used; the generic IPI
workflow in this change does not install an infrastructure firewall. Do not
promote this optional job to a merge gate before that verification and rehearsal.

Redaction covers the model and known preparation credentials, embedded target
credentials, private keys, common credential fields and bearer tokens. Do not use
restricted Jira source material in public jobs without checking the generated
plan's disclosure policy: a useful plan necessarily describes issue requirements.
Raw Jira bodies, diffs, prompts, model responses and kubeconfigs are not published.

## Artifacts and evaluation

Preparation writes `validation.md`, `validation.json`, `sources.json` and
`preparation-metrics.json`; failure writes `preparation-error.json`. Only the
checked plan and public source references enter SHARED_DIR. Execution publishes
the captured plan, `deployment.json`, per-command `evidence/`,
`partial-results.json`, final `results.json`, `report.md` and
`junit_agent_validation.xml`. Results include runner errors, runtime, selected
model and usage. Every unexecuted check is explicitly unable to verify. A report
states that passing observations establish tested behavior rather than proving
the entire issue resolved, particularly when Jira was unavailable.

Run focused checks from the repository root:

```sh
python3 -m unittest discover -s hack/agentic-validation -p 'test_*.py' -v
shellcheck ci-operator/step-registry/openshift/agentic/prepare-validation/*-commands.sh \
  ci-operator/step-registry/openshift/agentic/validate/*-commands.sh
make registry-metadata
make update
make validate-step-registry
make checkconfig
```

The unit tests use fake model responses and a Unix socket broker, and require no
service token or cluster. They check Jira/PR/inferred source rules, multiple-issue
scope, incomplete plans, revision/hash integrity, result/evidence validation,
failure precedence, missing output, bounded requests and cancellation/deadline
classification. They do not establish model quality or cluster compatibility.
The optional container smoke test is enabled with
`VALIDATION_SANDBOX_TEST_IMAGE=<runner-image>` when running the same test command
on a host with Podman. It checks a real API tunnel, blocked direct networking,
an empty secrets mount and writable fixtures without using any cluster credential.
It was also run locally against a small Python test image with a stub `oc`;
this verifies the container boundary, rather than the production image's `oc`.

For the first live demonstration, save one focused generated plan and run its
scenario against separately prepared known-broken and fixed clusters, retaining
their distinct revisions and deployment evidence. Compare the observations and
investigate checks that pass both versions. Also rehearse missing kubeconfig,
setup failure, an actual product assertion failure, timeout, cancellation,
missing tool support and incomplete model output. Repeat identical runs to
measure agreement, cost and review effort before making this a merge gate.
No model request, live cluster rehearsal or broken/fixed demonstration was run
as part of the local helper tests.
