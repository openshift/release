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

## Variants

| Variant | Purpose |
|---|---|
| *(none)* | Default config: builds images, runs presubmit/postsubmit tests, promotes |
| `__periodics` | Cron-scheduled tests. No image builds or promotion — pulls pre-built images from `hypershift` namespace |
| `__mce` | MCE (Multicluster Engine) integration tests. Uses `MCE_VERSION` env var |
| `__periodics-mce` | Periodic MCE tests. Agent-based, uses equinix-ocp-hcp cluster profile, includes Konflux flags |
| `__periodics-hcm` | Periodic HCM tests. Uses hypershift-operator from `acm-d` (external build), stable OCP releases only |
| `__okd-scos` | OKD with SCOS (Stream CoreOS) configuration |
| `__mce-multi-version` | Monthly MCE multi-version compatibility tests |

## Images Built (from main/release base configs)

- `hypershift-operator` — core operator (default Dockerfile)
- `hypershift` — control plane (Dockerfile.control-plane)
- `hypershift-tests` — e2e test binary (Dockerfile.e2e)
- `hypershift-cli` — operator + jq (derived image)

## Promotion Targets

- **ocp namespace** — hypershift image promoted to OCP release payload
- **hypershift namespace** — hypershift-operator and hypershift-tests with `latest` tag (consumed by periodic variants)
- **ci namespace** — hypershift-cli with `latest` tag

## Release Branch Configs

- Release configs pin OCP version in `base_images` (e.g., `"4.22"` instead of `"5.0"`)
- `config-brancher` manages release branch configs from main — do not manually edit brancher-managed release configs
- Periodic variants should go in separate `__periodics.yaml` files for CI analytical tooling

## Important Rules

- Never edit files in `ci-operator/jobs/` directly — edit config here and run `make update`
- After any config change, run `make update` to regenerate `zz_generated_metadata` and Prow jobs
- Commit both config and generated files together
