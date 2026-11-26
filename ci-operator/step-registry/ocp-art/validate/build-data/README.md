# Build-data validation

The shared presubmits validate LP and OCP metadata in `ocp-build-data`.
Each release branch needs a CI configuration referencing the `ocp-art-build-data`
workflow; new branches are not onboarded automatically. Tests run for every PR on the configured branch, including renames that move
metadata outside its expected directories. Required checks block merging on
validation errors.
Tide policy and branch protection are configured separately.

```text
branch CI configuration -> generated Prow job -> ocp-art-build-data workflow
  -> ocp-art-validate-build-data step -> uv run python -I -m validator.ci
```

## Checks

The validator checks:

- Metadata schemas, nonempty owners, and image names matching delivery repositories.
- Image and stream references, declared dependents, and parent-member cycles.
- Decreases in the configured product version compared with the PR target.
- Branches, Dockerfiles and configured manifests directories in both the private
  midstream and public upstream. The default Dockerfile is `Dockerfile`.
- Image and bundle repositories under their own components in stage and production RPAs.
- Production FBC catalog availability for configured `OCP_TARGET_VERSIONS`.

Disabled images are skipped. WIP findings are nonblocking. Images marked
`for_release: false` are excluded from RPA checks. A failed access check is
reported as an error rather than treated as evidence that a resource is missing.

## Runtime inputs

Each branch configuration sets `KONFLUX_APPLICATION` to select its stage and
production RPAs. Set this explicitly because rehearsals target the release PR
rather than a metadata PR.

The step fetches `ART_TOOLS_REF` (default `main`) outside the metadata checkout,
logs the checked-out commit, and uses its locked dependencies through `uv run`. Python `-I` prevents metadata PR
modules from shadowing the trusted validator. `RELEASE_DATA_REF` selects the
release-data revision (default `main`). The runtime uses internal CA trust and
intranet capability and writes `validation.json` to the job artifacts.

For each `OCP_TARGET_VERSIONS` entry, the validator inspects the production
`registry.redhat.io/redhat/redhat-operator-index:v<version>` manifest using Skopeo.
The existing `ci/ci-pull-credentials` bundle is mounted read-only at
`/var/run/secrets/ci-pull-credentials`; its `.dockerconfigjson` provides registry
pull authentication. No image layers are pulled. Missing catalogs and inability
to verify access are distinct failures; `--schema-only` skips registry checks.
Rehearsal must confirm the shared bundle is available and grants catalog access.

GitHub source checks use the existing private Git cloner credential from
`test-platform-infra/openshift-ci-robot/private-git-cloner`, mounted as
`/etc/github-private/oauth` and passed with `--github-token-file`. This follows
the credential declaration used by the `app-sre/infra` validation steps. The
validator uses the GitHub API to check branches, files and directories without
cloning private sources or downloading their contents into job artifacts.
Rehearsal must confirm credential availability and access to the private midstreams.

The validator checks the declared midstream independently of its public upstream.
An explicit `git.web` selects the public repository; when absent, the most
specific `public_upstreams` mapping supplies it. Public branch overrides apply
only to the public source. Missing or inaccessible sources remain errors.

`ART_TOOLS_REF` accepts a branch, tag or commit from `openshift-eng/art-tools`,
or `owner:ref` for a fork. It defaults to `main`.

## Local testing

From the trusted art-tools checkout:

```bash
uv run pytest ocp-build-data-validator/tests -q
uv run python -I -m validator.ci \
  --repo /absolute/path/to/acm-5.0-checkout \
  --schema-only --report /tmp/build-data-validation.json
```

For source, RPA and catalog checks, replace `--schema-only` with:

```text
--rpa-root /absolute/path/to/konflux-release-data/config
--application acm-5-0
--github-token-file /path/to/read-only-github-token
--registry-auth-file /path/to/registry-auth.json
```

After changing branch configs, run `make ci-operator-config jobs` and
`make registry-metadata`, then verify Prow formatting, semantics and pylint.
Commit source configs and generated jobs together; never edit the generated job
as the source of truth.

## Rehearsal and rollout

On the release PR, a different OpenShift org member must authorize network access:

```text
/pj-rehearse network-access-allowed
```

Then run the generated ACM job:

```text
/pj-rehearse pull-ci-openshift-eng-ocp-build-data-acm-5.0-art-build-data-validation
```

To request rehearsals for all affected first-pass jobs (up to 25), use
`/pj-rehearse max` after network access is authorized. The default command runs
at most five jobs; inspect the bot's affected-job list when selecting rehearsals.

After release merges, an ACM or MCE metadata PR can use `/test art-build-data-validation`.
The check context is `ci/prow/art-build-data-validation`. Inspect step logs and
`validation.json`; test a missing branch/Dockerfile, empty owners, mismatched name
and absent delivery repository, then restore valid metadata and confirm green.

LP force-push protection continues to use the repository's family regex, so new
matching branches receive protection independently of job onboarding. After
branchprotector reconciles, verify `allow_force_pushes.enabled: false` and
`enforce_admins.enabled: true` using GitHub's branch-protection API. No force-push
attempt is needed. Rehearsal does not apply branch protection.
