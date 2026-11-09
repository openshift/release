# Build-data validation

The optional ACM/MCE presubmits follow the existing `art-konflux-delivery-repo-check`
configuration pattern:

```text
ci-operator/config/openshift-eng/ocp-build-data/openshift-eng-ocp-build-data-<branch>.yaml
  -> generated branch-specific Prow presubmit
  -> ocp-art-build-data workflow
  -> ocp-art-validate-build-data step
  -> uv run --locked --no-dev python -I -m validator.ci
```

The first pass covers every existing ACM and MCE release branch:

- ACM: `2.11`, `2.13`, `2.14`, `2.15`, `2.16`, `2.17`, `5.0`, `5.1`.
- MCE: `2.6`, `2.8`, `2.9`, `2.10`, `2.11`, `2.17`, `5.0`, `5.1`.

All 16 jobs remain optional while baseline findings are corrected. Each additional
branch needs its own CI configuration referencing the same workflow. New y-streams
are not automatically onboarded to the job. A `__periodics.yaml` variant is only
needed for scheduled runs. Tide merge policy and branch protection are separate.

## Checks

The validator reuses OCP YAML/schema, release, and basic member/stream validation,
and adds the ticket's ownership, delivery-name, source-branch and Dockerfile checks:

- Owners must be nonempty, and image `name` must match a delivery repository name.
- The configured public upstream must have a usable target/fallback branch.
- The explicit Dockerfile, or `Dockerfile` by default, must exist in that source.
- Delivery repositories, bundle repositories and image components must be present
  in both stage and prod RPAs.

The RPA presence contract comes from the existing
[OCP delivery-repos step](https://github.com/openshift/release/blob/38a9915664e8c834b568f855e7e30072ad71b210/ci-operator/step-registry/ocp-art/validate/delivery-repos/ocp-art-validate-delivery-repos-commands.sh).
Repository and component presence are independent; a separate bundle component
is not required. Disabled and non-release images are excluded from RPA checks.
Disabled images are skipped; WIP findings are nonblocking. No additional
builder/dependent cycle policy is introduced. Parent `from.member` cycles and
self-references are rejected, matching Doozer's existing ancestry validation.

## Runtime inputs

Each branch config supplies its application, e.g. `KONFLUX_APPLICATION: acm-5-0` to select its RPAs, just as
OCP supplies `OCP_VERSION` to its delivery-repos check. It is explicit because a
rehearsal's primary PR targets release/main, not the ACM metadata branch.

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

Public source branches and files are checked anonymously using GitHub web URLs,
following the existing OCP validator. No GitHub token or GitHub credential is required.
`public_upstreams` selects the public source instead of its private mirror, with
repo-specific mappings and public branch overrides respected. Without a mapping,
the declared source is checked; inaccessible sources remain errors. Private mirrors
are not checked separately by this token-free presubmit.

Use `owner:ref` to fetch from a fork; an unqualified branch, tag or commit uses
`openshift-eng/art-tools`. Merge the art-tools validator PR before merging release
or rehearsing with the `main` default. Subsequent runs pick up art-tools main
updates. OCP job migration is separate work.

## Local testing

From the trusted art-tools checkout:

```bash
uv run pytest ocp-build-data-validator/tests -q
uv run python -I -m validator.ci \
  --repo /absolute/path/to/acm-5.0-checkout \
  --schema-only --report /tmp/build-data-validation.json
```

For source and RPA checks, replace `--schema-only` with:

```text
--rpa-root /absolute/path/to/konflux-release-data/config
--application acm-5-0
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
