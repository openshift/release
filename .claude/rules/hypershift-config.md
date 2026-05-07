---
paths:
  - "ci-operator/config/openshift/hypershift/**"
  - "ci-operator/config/openshift-priv/hypershift/**"
---

# HyperShift CI Configuration

## File Naming

Config files follow `openshift-hypershift-{branch}[__{variant}].yaml`:
- `openshift-hypershift-main.yaml` — main branch, builds all images
- `openshift-hypershift-release-4.22.yaml` — release branch, pins OCP version in base_images
- `openshift-hypershift-release-4.22__periodics.yaml` — periodic variant

Files in `openshift-priv/hypershift/` use the prefix `openshift-priv-hypershift-*` (e.g., `openshift-priv-hypershift-main.yaml`).

## Variants

| Variant | Purpose |
|---|---|
| *(none)* | Default config: builds images, runs presubmit/postsubmit tests, promotes |
| `__periodics` | Cron-scheduled tests. No image builds or promotion — pulls pre-built images from `hypershift` namespace |
| `__mce` | MCE image build and publishing. Builds hypershift-operator via stolostron toolchain for backplane registry (postsubmit only, releases 4.12-4.19) |
| `__periodics-mce` | Periodic MCE integration tests across platforms (agent, AWS, kubevirt, IBM Z, Power). Uses `MCE_VERSION` env var. Konflux flags in 4.21+ |
| `__periodics-hcm` | Periodic HCM tests (releases 4.16-4.21 only). Uses hypershift-operator from `acm-d` (external build), GA OCP releases (fast channel) only |
| `__okd-scos` | OKD with SCOS (Stream CoreOS) configuration (main and release-4.21) |
| `__mce-multi-version` | Monthly MCE multi-version compatibility tests |
| `__equinix-cleanup` | Periodic equinix cluster leak checker (runs every 30 min). Uses `equinix-ocp-hcp` cluster profile |

## Images Built (from main/release base configs)

- `hypershift-operator` — core operator (default Dockerfile)
- `hypershift` — control plane (Dockerfile.control-plane)
- `hypershift-tests` — e2e test binary (Dockerfile.e2e)
- `hypershift-cli` — operator + jq (derived image, main and 4.23+ release configs)

Note: Image builds vary by release branch. Recent releases (4.23+) build all 4 images including `hypershift-cli`. Release 4.22 builds 3 images (no `hypershift-cli`). Releases 4.14-4.21 build only `hypershift` (control plane image), importing operator and test images from the `hypershift` namespace. Releases 4.12-4.13 build both `hypershift-operator` and `hypershift` (2 images). The main config is the canonical reference for the current image set.

## Promotion Targets

- **ocp namespace** — hypershift image promoted to OCP release payload
- **hypershift namespace** — hypershift-operator and hypershift-tests with `latest` tag (consumed by periodic variants)
- **ci namespace** — hypershift-cli with `latest` tag

Release branch configs promote to the `ocp` namespace with the release version name. Releases 4.21-4.22 exclude `hypershift-operator` and `hypershift-tests` from promotion. Releases 4.23+ additionally exclude `hypershift-cli`. Release branches do not promote to `hypershift` or `ci` namespaces.

## Release Branch Configs

- Release configs pin OCP version in `base_images` (e.g., `"4.22"` instead of `"5.0"`)
- `config-brancher` manages release branch configs from main — do not manually edit brancher-managed release configs
- Main currently targets release `5.0`. Release branch configs exist for 4.12 through 5.1 (older releases like 4.12-4.17 may no longer be actively maintained)
- Periodic variants should go in separate `__periodics.yaml` files for CI analytical tooling

## Important Rules

- Never edit files in `ci-operator/jobs/` directly — edit config here and run `make update`
- After any config change, run `make update` to regenerate `zz_generated_metadata` and Prow jobs
- Commit both config and generated files together
