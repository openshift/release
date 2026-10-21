# Quay CI config generator

`generate.py` turns one short file, `matrix.yaml.in`, into the Quay
[ci-operator](https://docs.ci.openshift.org/) configs under
`ci-operator/config/quay/quay/` and `ci-operator/config/quay/quay-operator/`.
Edit the matrix or the templates, never the generated configs.

## Quick start

All commands run from the `openshift/release` root.

```bash
# 1. Edit _generator/matrix.yaml.in (or a template), then regenerate the configs
make -C ci-operator/config/quay/quay/_generator generate

# 2. Normalize the configs and regenerate the Prow jobs
make update

# 3. Run the generator's tests and check the configs are up to date
make -C ci-operator/config/quay/quay/_generator check
```

Commit the matrix or template change together with the regenerated files under
`ci-operator/config/quay/{quay,quay-operator}/` and
`ci-operator/jobs/quay/{quay,quay-operator}/`.

Step 3 is also the CI gate: the `pull-ci-openshift-release-main-quay-quay-quay-quay-check`
presubmit (`/test quay-quay-quay-quay-check`) runs it whenever
`ci-operator/(config|jobs)/quay/(quay|quay-operator)/` changes.

`make generate` adds a `# DO NOT EDIT` header to each file; `make update`
strips it again, so committed configs carry no header.

## How it works

```
matrix.yaml.in ──> generate.py ──> one config file per cell ──> make update ──> Prow jobs
  releases           expands each job       ci-operator/config/quay/...        ci-operator/jobs/quay/...
  jobs               across clouds × ocp × arches,
                     merges template layers
```

- Each row under `quay[].jobs` expands into cells: one per cloud × OCP version × arch.
- Each cell is rendered by deep-merging Jinja templates from `templates/`
  (base, source, cloud, arch, test; see [Layer order](#layer-order)).
- Cells that share a filename merge into one file; their tests are listed in matrix order.
- `matrix.yaml.in` lists every file the generator owns under `managed_files.active`.
  Generation fails if that list and the expanded matrix disagree.
  Files not listed (such as `quay-quay-master__claim.yaml`) are hand-written and ignored.

## Common tasks

Every task ends with the three [Quick start](#quick-start) commands. A task that
creates a new file also needs that filename added to `managed_files.active`;
otherwise generation fails with `generated but not active`.

**Add a Quay release.** Append to `quay:`. This adds
`quay-quay-redhat-3.19__aws-ocp422-e2e-install.yaml`:

```yaml
  - branch: redhat-3.19
    jobs:
      - {cron: daily, source: nightly, clouds: [aws], ocp: ["4.22"], test: e2e-install}
```

**Add an OCP version to a job.** Extend its `ocp` list; each new version is a
new file (`...__aws-ocp423-e2e-install.yaml`):

```yaml
        ocp: ["4.22", "4.23"]
```

**Add a cloud.** Extend `clouds` (`aws`, `gcp`, `azure`, `libvirt`). Each cloud
gets its own file and its default storage (`STORAGE_BY_CLOUD` in `model.py`).

**Add a stable-catalog job next to a nightly one.** `source` is not part of the
filename, so both rows land in one file as `aws-s3-nightly` and `aws-s3-stable`:

```yaml
      - {cron: daily, source: nightly, clouds: [aws], ocp: ["4.22"], test: e2e-install}
      - {cron: daily, source: stable,  clouds: [aws], ocp: ["4.22"], test: e2e-install}
```

**Add a variant of an existing job** (FIPS, managed database, ODF storage).
Add a sibling row with the flag. It shares the file and gets a distinct test
name, such as `aws-s3-nightly-fips`, `aws-s3-rds-nightly` or `aws-odf-nightly`:

```yaml
      - {cron: weekly, source: nightly, clouds: [aws], ocp: ["4.22"], test: e2e-install, fips: true}
```

**Add an operator upgrade lane.** Only the previous Quay version is needed;
channels, branches and the test name (`from-317`) are derived:

```yaml
      - {cron: weekly, source: nightly, clouds: [aws], ocp: ["4.22"], test: upgrade, upgrade_from: "3.17"}
```

**Add a quay-operator Chainsaw job.** One row plus its
`quay-quay-operator-{branch}__aws-ocp{ocp_nodot}-e2e-chainsaw.yaml` line in
`managed_files.active`:

```yaml
      - {cron: weekly, source: nightly, clouds: [aws], ocp: ["5.0"], test: e2e-chainsaw}
```

**Override env for one branch or one job.** `env` on a release applies to
every job on that branch; `env` on a job overrides it. Values replace whole
keys. Do not copy `QUAY_EXTRA_CONFIG` here; it comes from the test template.

```yaml
  - branch: redhat-3.16
    env:
      PLAYWRIGHT_GREP_INVERT: "@auth:OIDC|@auth:LDAP"
```

**Stop generating a file.** Remove its row and move the filename from
`managed_files.active` to `managed_files.retired`. Delete the file, then drop it
from `retired` once it is gone; `--check` fails while a retired file still exists.

**Preview without writing.** From `_generator/`, using the venv `make` creates
(`/tmp/quay-ci-generator-venv` by default):

```bash
/tmp/quay-ci-generator-venv/bin/python generate.py --list      # table of every cell: file, test name, cron
/tmp/quay-ci-generator-venv/bin/python generate.py --dry-run   # print the YAML
/tmp/quay-ci-generator-venv/bin/python generate.py --check     # exit 1 if any managed file is stale
```

`--output DIR` writes or checks another directory instead of the in-tree ones;
`e2e-chainsaw` configs go to `DIR/../quay-operator`. `--check` compares parsed
YAML, so the header and quoting differences do not count as stale.

## Reference

### `matrix.yaml.in` fields

Top level:

| Field | Meaning |
| --- | --- |
| `version` | Matrix format version (`2`). |
| `global_defaults.repo` | `org/repo` for filenames and metadata (`quay/quay`). A test in `REPO_BY_TEST` (`model.py`) writes to its own repo instead: `e2e-chainsaw` -> `quay/quay-operator`. |
| `global_defaults.arch` | Default cluster arch (`amd64`). |
| `global_defaults.image_source` | Reserved (`build`); no template reads it yet. |
| `managed_files.active` | Every file the matrix must generate, exactly. |
| `managed_files.retired` | Files the generator no longer owns; `--check` fails while any still exists. |

Per release, `quay[]`:

| Field | Meaning |
| --- | --- |
| `branch` | `redhat-X.Y` or `master`. The Quay version is `X.Y`; `master` has none. |
| `layout` | `variant` (default): `{org}-{repo}-{branch}__{variant}.yaml`. `base`: `{org}-{repo}-{branch}.yaml` (used for `master`). |
| `env` | Env for every job on the branch. |
| `jobs` | Job rows, below. |

Per job, `quay[].jobs[]`:

| Field | Meaning |
| --- | --- |
| `test` | `e2e-install` (Playwright e2e, `quay/quay`), `upgrade` (operator channel upgrade, `quay/quay`) or `e2e-chainsaw` (operator Chainsaw suites, `quay/quay-operator`, periodic only). Picks `templates/tests/{test}.yaml.j2`. |
| `kind` | `periodic` (default) or `presubmit` (renders `templates/presubmit/` where present). |
| `cron` | Periodic only, required: `daily` or `nightly` (both `@daily`), `weekly` (`@weekly`), or a raw 5-field cron used verbatim. Changes timing only, never the test name. |
| `source` | Periodic only, required: `nightly` (ART FBC catalog, `QUAY_INDEX_IMAGE_REPO`; `e2e-install` and `upgrade` also set `PLAYWRIGHT_REF_MODE: strict`) or `stable` (`redhat-operators`). |
| `clouds` | `aws`, `gcp`, `azure`, `libvirt`. |
| `ocp` | OCP versions, as strings (`"4.22"`). |
| `arches` | `amd64`, `arm64`, `s390x`; defaults to `[global_defaults.arch]`. |
| `as` | Test name. Default `{cloud}-{storage}-{source}` (periodic) or `{cloud}-{storage}` (presubmit). Two rows in one file with the same name fail with `duplicate as`; set `as` on one of them. |
| `env` | Job env; overrides branch env key by key. |
| `always_run`, `optional`, `run_if_changed`, `skip_if_only_changed` | Presubmit only, copied onto the test. `run_if_changed` and `skip_if_only_changed` exclude each other; `always_run: true` excludes both. |
| `fips` | Periodic only. FIPS cluster, `fips-check-fips-or-die` first, `FEATURE_FIPS: true`, Mailpit off (so `@feature:MAILING` specs skip). Adds `-fips` to the name. Not with `upgrade` or `e2e-chainsaw`. |
| `sts` | Default `true`, `aws` cells only. Installs with CCO Manual mode and STS (`ipi-aws-pre-manual-oidc-sts` / `ipi-aws-post-manual-oidc-sts`). Quay's own S3 storage still uses static keys. |
| `database` | `true` provisions a managed Postgres (`DATABASE_BY_CLOUD` in `model.py`: AWS RDS, Azure Postgres) and removes it in `post`. Not on `gcp` or `libvirt`. Adds the DB kind to the name (`aws-s3-rds-nightly`). |
| `storage` | Override the cloud's default storage. Besides that default, only `odf`, only on `aws`. `e2e-chainsaw` always uses `odf`. |
| `upgrade_from` | Required for `upgrade`, invalid elsewhere: the previous Quay `X.Y`. Derives both channels, both branches and the name `from-<XY>`. |
| `ocp_channel` | `upgrade` only: `stable` (default) or `candidate`, for an OCP minor without a stable channel yet. |

### File naming

- `layout: variant`: `{org}-{repo}-{branch}__{cloud}-ocp{ocp_nodot}-{test}.yaml`.
  A non-`amd64` arch goes into the variant: `{cloud}-{arch}-ocp{ocp_nodot}-{test}`.
  `upgrade` files carry the storage too: `aws-ocp422-s3-upgrade`.
- `layout: base`: `{org}-{repo}-{branch}.yaml`, or `{org}-{repo}-{branch}__{arch}.yaml`
  for a non-`amd64` arch. A base file holds one OCP version; another needs a
  separate `layout: variant` entry for the branch.
- Cells sharing a file must render the same config outside `tests`, or
  generation fails with `incompatible file-level inputs`.

### Layer order

Each cell deep-merges these layers; later layers win:

1. `templates/base.yaml.j2` (presubmit: `templates/presubmit/base.yaml.j2`;
   a repo with `templates/repos/{repo}/base.yaml.j2` uses that instead)
2. `templates/sources/{source}.yaml.j2` (periodic only)
3. `templates/clouds/{cloud}.yaml.j2` (presubmit: `templates/presubmit/clouds/{cloud}.yaml.j2` if present)
4. Non-`amd64` only, both required: `templates/arches/{arch}.yaml.j2`, then `templates/clouds/{cloud}-{arch}.yaml.j2`
5. `templates/tests/{test}.yaml.j2`
6. Presubmit only: `templates/presubmit/tests/{test}.yaml.j2` if present
7. `cron` (periodic) or the trigger fields (presubmit)
8. Branch `env`, then job `env` and `as`

Merge rules: mappings recurse, lists of mappings merge by index, scalar lists
and env values replace. Templates use `{{ variable }}` and `{% if %}` on cell
fields (`test`, `source`, `arch`, `layout`, `storage`, `fips`, `sts`,
`quay_version` and others); expansion and merging live in `generate.py`.

### Per-test notes

- **`e2e-install`, `upgrade`**: `QUAY_EXTRA_CONFIG` is defined once, in
  `templates/tests/_e2e-install.defaults.j2`, and shared by both.
  `FEATURE_ROBOT_API_TOKENS` is added for Quay 5.0 and later.
- **`upgrade`**: installs a released OCP (`releases.latest` is a stable
  `release`, not the nightly payload) and moves the Subscription channel itself,
  so `QUAY_OPERATOR_CHANNEL` is not set.
- **`e2e-chainsaw`**: installs ODF (NooBaa) and the operator from the ART
  nightly catalog on channel `stable-{quay_version}`, then runs
  `quay-test-chainsaw` with `CHAINSAW_SUITE: all` (e2e, then destructive) under
  a 4h timeout. Uses `templates/repos/quay-operator/base.yaml.j2` and the
  `aws-quay-qe` cluster profile.
- **`storage: odf`**: inserts `quay-install-odf-operator` and deploys with
  `quay-deploy-odf`; the operator manages object storage, and
  `quay-deprovision` skips bucket teardown.
- **`libvirt` / `s390x`**: S3 storage; the `s390x` cell installs through the
  IBM Z libvirt workflow (`quay-tests-libvirt-s390x`).
- **`arches`**: `releases.latest` stays `amd64` for build tooling; the arch
  layer adds the test cluster's release. A non-`amd64` `layout: base` file
  never promotes.

### Tests

`make check` runs `pytest`, then `generate.py --check`. Golden-output tests use
`tests/fixtures/matrix-phase0.yaml.in`, not the real matrix, so adding coverage
to `matrix.yaml.in` needs no test changes.
