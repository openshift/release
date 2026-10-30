# Shared build-data validation

This step runs `python -I -m validator.ci` from a trusted art-tools installation
against the metadata PR checkout. It is used by the `ocp-art-build-data` workflow.
It provisions no test cluster and makes no changes to GitHub or Konflux.

## Execution

1. ci-operator creates a Python 3.11 runtime from the job's build-root definition.
   Package and CA setup runs as root during image construction; validation runs as UID 1001.
2. The step clones the configured ART tools ref outside the metadata checkout and
   installs dependencies from its lockfile with `uv sync --locked --no-dev`.
3. It clones internal konflux-release-data with normal TLS verification.
4. It checks schemas, owners, image/delivery names, source refs and Dockerfiles,
   metadata paths, image/member/stream references, dependency cycles, and stage/prod
   RPA repository and component mappings. Disabled images are skipped; WIP errors
   are warnings. Non-release images still receive source/ownership checks.
5. It writes `validation.json` in the step artifacts and exits nonzero on errors.

All metadata is checked during the initial optional rollout. The CLI supports
`--base-ref <SHA>` for later changed-file validation; shared metadata changes and
image deletions trigger a full pass. Keeping Prow checks optional does not hide
failures: the job reports failure without blocking Tide.

## Rollout prerequisites

- Merge the ART tools change providing `validator.ci` before merging this configuration.
  `ART_TOOLS_REF` pins the reviewed implementation to an immutable commit. Update
  that revision deliberately when adopting validator changes.
- Provision Google Secret Manager collection `art`, group `build-data-validation`,
  field `github-token`. Grant the CI job access according to the CI secrets process.
  The value must be a read-only GitHub token limited to the configured source repos.
  It is mounted as `/var/run/art-build-data-validation/token`; no token is committed.
- The runtime must reach GitHub, Python dependency sources, certs.corp.redhat.com,
  and gitlab.cee.redhat.com. Jobs request intranet capability. The runtime's CA
  installation and locked dependency install have been tested locally.
- `KONFLUX_APPLICATION` defaults to the Prow target branch with dots replaced by
  dashes, matching current Doozer application naming. Set an explicit override for
  legacy applications. Missing stage/prod mappings are errors, not skipped checks.
- Baseline each branch, correct metadata/application configuration, then promote
  jobs to required. Retain OCP GitHub Actions until a separate migration confirms
  parity. OCP can use this same workflow without a new implementation.

One handwritten Prow presubmit supplies `UNRESOLVED_CONFIG` to ci-operator and
matches numeric major/minor LP release branches by product family. The registry
workflow resolves through configresolver; no branch-specific CI file is needed.
For example, a new oadp-1.7 or logging-6.8 branch automatically uses this job.
The target application is derived from the actual Prow branch, not a fixed version.
A new product family needs one addition to the shared job/protection regex.

Prow branch protection uses the same family pattern in its repository-level
`include` policy. New matching branches receive force-push protection on the next
branchprotector reconciliation. Nonmatching OCP, tooling, main and developer
branches retain their existing protection. Existing Tide merge-policy onboarding
is separate and unchanged.

## Testing locally

Use a release-branch checkout containing `group.yml`; main has no release metadata.
Commands below assume the shell is in a trusted art-tools checkout. Always use
isolated Python when the metadata checkout may contain untrusted Python modules.

```bash
.venv/bin/python -m pytest ocp-build-data-validator/tests -q
.venv/bin/python -I -m validator.ci \
  --repo /absolute/path/to/release-branch-checkout \
  --schema-only --report /tmp/build-data-validation.json
```

`--schema-only` runs schema and local semantic/reference checks. To exercise all
checks with read-only credentials and an existing local release-data checkout:

```bash
.venv/bin/python -I -m validator.ci \
  --repo /absolute/path/to/release-branch-checkout \
  --github-token-file /absolute/path/to/read-only-token-file \
  --rpa-root /absolute/path/to/konflux-release-data/config \
  --application zero-trust-1-1 \
  --report /tmp/build-data-validation.json
```

The executable runner security test runs the real installed validator with
network/setup commands stubbed and hostile modules in the PR checkout:

```bash
# From openshift/release, using the art-tools environment:
/path/to/art-tools/.venv/bin/python -m unittest discover \
  -s hack/art-build-data -p 'test_*.py' -v
```

## Testing in Prow

First publish the art-tools implementation to a test ref (or merge it) and provision
its credential. Open the release configuration PR and use the repository's rehearsal
process to exercise the new job before merging. Rehearsal requires a trusted
maintainer and the configured secret/intranet access; YAML checks alone do not
prove private-source access. The release PR bot lists this job as rehearsable.
Because the step needs network access, an OpenShift organization member other
than the PR author must first comment on the release PR:

```text
/pj-rehearse network-access-allowed
```

Then request just this job on the same PR:

```text
/pj-rehearse pull-ci-openshift-eng-ocp-build-data-validation
```

This is the pre-merge test; `/test art-build-data-validation` on a metadata PR
becomes available after the release configuration is merged. Rehearsal does not
apply branch protection. After merge, check matching branches through GitHub's
branch-protection API for `allow_force_pushes.enabled: false` and
`enforce_admins.enabled: true`; a force-push attempt is unnecessary.

After the release configuration merges, open an LP metadata PR and use:

```text
/test art-build-data-validation
```

The check context is `ci/prow/art-build-data-validation`. Inspect the
`ocp-art-validate-build-data` step logs and its `validation.json` artifact. Try a
missing Dockerfile/ref, an empty owners list, a missing member/stream, a cycle,
and a mismatched delivery name on a disposable metadata PR. Fix each change and
confirm the same job returns green.

## Configuration verification

Run `make registry-metadata sanitize-prow-jobs` and Prow checkconfig. The shared
job is handwritten so prowgen must not own it. Validate its `UNRESOLVED_CONFIG`
payload with ci-operator-checkconfig and the registry resolver, without adding a
branch-specific file to ci-operator/config.
The current configresolver's validate-only mode still constructs a Kubernetes
client, and the current `make validate-step-registry` passes a removed `--prow-config`
flag. Use the current binary's `--config`, `--registry`, `--validate-only` options
with an offline placeholder kubeconfig to validate locally without cluster access.
Prow checkconfig must use relative repository paths with the pinned October 23
binary; its filesystem walker rejects the make target's absolute supplemental path.
These are existing tool compatibility issues, not job runtime requirements.
