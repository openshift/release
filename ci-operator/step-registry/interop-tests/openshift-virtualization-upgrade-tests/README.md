# interop-tests-openshift-virtualization-upgrade-tests

CNV **upgrade-only** tests on the ACM **spoke** cluster. Follows
[INSTALL_AND_UPGRADE.md](https://github.com/RedHatQE/openshift-virtualization-tests/blob/main/docs/INSTALL_AND_UPGRADE.md)
(`--upgrade cnv`).

Spoke **OCP** upgrade is **not** performed here — use `acm-interop-p2p-spoke-upgrade` before this step.

## Default upgrade path

| From | To | Catalog |
|------|-----|---------|
| CNV 4.20 (installed by p2p-acm-cnv-install-policy on stable) | CNV 4.21.0 GA | `CNV_SOURCE=production`, `CNV_CHANNEL=stable` |

All pytest invocations pass `--ignore=tests/network/` (interop clusters are not multi-NIC).

## Pytest invocation

One `pytest --upgrade cnv` run with pre/post upgrade validation (full upgrade suite per
`INSTALL_AND_UPGRADE.md`).

## Typical workflow placement

```yaml
test:
- ref: acm-interop-p2p-cluster-upgrade      # hub OCP
- ref: acm-interop-p2p-spoke-upgrade        # spoke OCP via ACM ManifestWork
- ref: interop-tests-openshift-virtualization-upgrade-tests  # CNV 4.20 -> 4.21 GA
env:
  CNV_TARGET_VERSION: "4.21.0"
  CNV_SOURCE: "production"
  CNV_CHANNEL: "stable"
```

## Env vars (ref.yaml)

| Name | Default | Purpose |
|------|---------|---------|
| `CNV_VERSION_EXPLORER_URL` | *(empty)* | CNV Version Explorer API base URL for `--upgrade cnv`. Known URL: https://cnv-version-explorer.apps.cnv2.engineering.redhat.com/ — auto-resolved when empty (see below). |
| `CNV_TARGET_VERSION` | `4.21.0` | `--cnv-version` target |
| `CNV_TARGET_IMAGE` | *(empty)* | Optional `--cnv-image`; omit for production GA |
| `CNV_SOURCE` | `production` | `--cnv-source` |
| `CNV_CHANNEL` | `stable` | `--cnv-channel` |
| `CNV_TARGET_STORAGE_CLASS` | `ocs-storagecluster-ceph-rbd-virtualization` | Boot images + pytest SC |
| `CNV_BOOT_IMPORT_CRON_UPTODATE_WAIT_TIMEOUT` | `20m` | Per-cron `oc wait` UpToDate during boot image prep |
| `CNV_DV_NAMESPACE_PVC_RETRY_WAIT_TIMEOUT` | `300` | PVC idle retry after force-delete of stuck PVCs |

### `CNV_VERSION_EXPLORER_URL` resolution

Required by `openshift-virtualization-tests` for `--upgrade cnv`. When not set in job/step `env:`,
the step resolves it in order:

1. **`CNV_VERSION_EXPLORER_URL`** environment variable (explicit override)
2. **`${BW_PATH}/cnv-version-explorer-url`** — file in `openshift-virtualization-tests-credentials`
3. **Bitwarden Secrets Manager** — `bws secret list/get` for `cnv_version_explorer_url`,
   `CNV_VERSION_EXPLORER_URL`, or `default_cnv_version_explorer_url`

Diagnostics (availability only — no URLs or secret values): `${ARTIFACT_DIR}/cnv-version-explorer-url-check.txt` and
`cnv-version-explorer-url-source.txt`. CI logs use the same availability-only messages via `:` (no secret values).

## Artifacts

| File | Content |
|------|---------|
| `cnv-boot-image-prep-mode.txt` | Boot image prep mode (`wait_only`) |
| `junit_results.xml` | Full upgrade suite JUnit output |
| `tests.log` | Pytest log |
| `cnv-version-explorer-url-check.txt` | Which URL sources were checked (env / mount / Bitwarden) |
| `cnv-version-explorer-url-source.txt` | Winning source (`environment`, `credentials-mount`, or `bitwarden:<name>`) |
