# Agentic OLS disconnected GPU periodic (OLS-4227)

Job: `periodic-ci-openshift-lightspeed-agentic-operator-main-5.0-e2e-disconnected-gemma`

Schedule: Sunday at **08:10 UTC** (`10 8 * * 0`). Job timeout is 18 hours;
connected provisioning is bounded to 2 hours and the core product suite to 12 hours.

## Cluster and inputs

The job claims the existing `obs` OCP **5.0**, AWS/amd64 GPU pool. Selectors use
**us-east-1**, matching the pool's actual metadata and AWS configuration, even
though its manifest filename ends in `aws-us-east-2_clusterpool.yaml`.
The pool uses `g5.12xlarge` workers for the four-GPU Gemma 4 profile.

The operator image is built from the periodic's source checkout. Prow also
generates an ordinary `5.0-images` presubmit to validate that image build.
The runner build-root includes Python, jq, gettext/envsubst, and util-linux
(setsid/timeout support), in addition to the Go tooling image's build tools.

Credentials reuse `openshift-lightspeed-service-creds`:

- `huggingface/token`: must have access to the gated Gemma model/template.
- `vllm-apikey/token`: authenticated inference key.

`LIGHTSPEED_SERVICE_REF` in the CI config pins a merged upstream service commit
with `tests/rhoai` Gemma 4 assets. Update deliberately when changing provisioning.
The operator's `make product-e2e-disconnected` entrypoint (OLS-4226) must be present
on `main`; this was verified against upstream during implementation.

## Connected preparation and restricted runtime

The runner authenticates to the CI registry with its build-cluster service
account, merges the claimed cluster's pull secret, and obtains a temporary
registry push token. Registry authentication files are private and never archived.
It enables the claimed cluster's registry route, then mirrors:

1. The operator built by this job.
2. `SANDBOX_SOURCE_IMAGE`: the real Agentic OLS sandbox image.
3. `SKILL_SOURCE_IMAGE`: the image used by the current core troubleshooting scenarios.

Images are consumed by **cluster-internal registry service pullspecs pinned to the
mirrored digests**, not by the external registry route. Pull access is scoped to
service accounts in `openshift-lightspeed`. `E2E_SKILL_IMAGE_MAP` passes the explicit
skill mapping to the existing suite. If core scenarios introduce another skill
image, extend mirroring/mapping here; unmapped external images fail closed rather
than falling back to external pulls. This is not a scenario allowlist.

The existing product harness provisions RHOAI/KServe/Gemma while connected, then
runs `product_e2e` with `E2E_SCENARIO_TAGS=core`, preflight checks, and its
NetworkPolicy-based restricted sandbox boundary. This is restricted runtime E2E,
not an air-gapped cluster installation. There is no LSEval or external LLM provider.
The runner invokes the suite once and preserves failures; it never retries after
restoring egress.

## Artifacts and cleanup

Artifacts include input image digests, the skill mapping, redacted provisioning/
product output, inference status and model logs, plus the existing product
harness's diagnostics. `generic-claim` retains its gather chain, including
must-gather, extra resources, and audit logs. Secrets/auth files are not artifacts.

The product harness owns policies, probes, test resources, and operator cleanup.
The runner gathers model diagnostics and removes its image namespace on exit;
cleanup failure fails an otherwise successful run but never masks a test failure.
The cluster claim is disposable and ci-operator deletes it after post steps,
including after a runner timeout. RHOAI installation and registry route changes
exist only on that disposable cluster.

## Local checks and first live run

From the release repository root:

```bash
shellcheck ci-operator/step-registry/openshift/lightspeed-agentic-operator/e2e/disconnected/*-commands.sh
```

This lint check does not consume a GPU claim.
CI configuration and job generation use the standard release tooling containers.
Before relying on the periodic, trigger one real Prow run to verify pool availability,
registry routing/push/pull, Hugging Face access, and RHOAI/vLLM compatibility with
OCP 5.0. Local lint checks cannot establish those cluster-dependent properties.
