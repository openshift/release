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

The BuildConfig installs Python 3.12, bash, Git and diffutils on the existing nested-podman
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
3. `generate_plan` requests schema-constrained JSON for focused checks, attaches
   trusted source metadata, validates every check, and computes the plan hash.
   Ready plans rejected by validation receive at most two correction attempts.
   Plans declaring unresolved gaps remain fatal and are not forced into readiness.
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
   container runs the tested payload component digest. Execution receives those
   verified namespace, Pod and container identities as discovery context.
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

The same credential group must contain `ca-bundle`, obtained from Red Hat's
official corporate CA distribution. `VALIDATION_MODEL_CA_FILE` defaults to that
mounted file. The model client adds it to system trust and continues to verify
certificates and hostnames. The corporate CA stays in the credential store and
outside generated command containers. Set this parameter empty when using an
endpoint that needs only the system CA bundle.

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

Preparation requires `json_schema` response formatting. Execution requests required
native function calls, binds check-ID enums to the captured plan, and exposes result
recording only after command evidence exists. The sandbox checks for `oc` and `diff`
and creates `/work/evidence` for command scratch files; report evidence is still
captured separately by the supervisor.

## Cluster and credential boundaries

Generated commands run in a networkless, read-only nested container with dropped
capabilities, no-new-privileges, resource limits, and bounded writable tmpfs mounts.
Only the target kubeconfig and API-broker Unix socket are mounted. The supervisor
retains model and registry credentials; preparation alone receives Jira credentials.
Registry authentication is passed explicitly to payload inspection and image pulls.
The broker permits CONNECT only to the assigned API's pre-resolved addresses.

The broker does not isolate workloads created through the cluster API. Those
workloads retain the assigned cluster's network access and API permissions.
The optional AWS consumer uses ordinary IPI networking; it does not establish
infrastructure-level egress isolation for privileged or host-networked workloads.

## Verification

The manual, optional `aws-ipi` job in
`ci-operator/config/openshift/release/openshift-release-main__agentic-rehearsal.yaml`
installs an OpenShift 5.1 nightly on AWS with `ipi-aws` and the
`openshift-org-aws` cluster profile. After installation it runs the actual
`openshift-agentic-prepare-validation` and `openshift-agentic-validate` references.
Execution uses the installed cluster's kubeconfig and verifies the deployed
`haproxy-router` payload digest. The inherited `ipi-aws` post chain gathers and
destroys the cluster, including when validation fails.

Temporarily put a suitable cluster issue's Jira key in the release PR title and
trigger `/pj-rehearse pull-ci-openshift-release-main-agentic-rehearsal-aws-ipi`.
Inspect `sources.json`, `validation.md`, deployment verification, command evidence,
`report.md`, results and JUnit. Restore the title after source capture. The runner
generates Markdown from the issue description; it does not download an existing
`validation.md` attachment. This release job tests the selected nightly's behavior;
it does not build a product component from the release repository's PR diff.

The runner must first be published as
`quay.io/openshift/ci:ci_agentic-validation_latest`, the image behind the
`ci/agentic-validation:latest` alias. Publishing an app.ci-local image stream alone
is insufficient. The consumer requires `intranet` and `nested-podman` capabilities
and runs on build03. Corporate endpoint reachability and CA trust must both be
present; certificate verification remains enabled.

Live corporate-model probes verified schema-constrained planning from Jira and
real-container pass/fail observations with retained evidence. Plan quality and
complete acceptance-criterion coverage still need review; these probes are not a
known-broken/fixed demonstration on an OpenShift cluster.
