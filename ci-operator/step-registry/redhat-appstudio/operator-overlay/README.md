# Operator overlay OpenShift CI steps

Job `konflux-ring-deployments-conformance-tests` exercises the **development-operator**
overlay on infra-deployments (`hack/bootstrap-cluster.sh preview --operator-overlay`).
This is the covering infra-deployments e2e (legacy `appstudio-e2e-tests` /
`development` preview without `--operator-overlay` was removed).

## Layout

ci-operator allows one step per leaf directory. Install and e2e are separate siblings:

| Directory | Ref (`as`) | `OVERLAY_E2E_SCRIPT_NAME` | Infra script |
|-----------|------------|---------------------------|--------------|
| `operator-overlay-install/` | `redhat-appstudio-operator-overlay-install` | `install.sh` | `install.sh` |
| `operator-overlay-e2e/` | `redhat-appstudio-operator-overlay-e2e` | `run-e2e.sh` | `run-e2e.sh` |

Each step has its own `*-commands.sh` (same clone/login logic; duplicated so Prow mounts only that step’s files). Product logic lives under `infra-deployments/components/konflux-operator/ci/openshift-overlay-e2e/`.

## CI image (`konflux-overlay-install`)

Built per job from infra-deployments (not promoted to `ci/`):

- **Dockerfile:** `components/konflux-operator/ci/openshift-overlay-e2e/Dockerfile`
- **Config:** `ci-operator/config/redhat-appstudio/infra-deployments/redhat-appstudio-infra-deployments-main.yaml` (`images:` + `build_root`)
- **Contents:** digest-pinned `quay.io/konflux-ci/task-runner` + Go 1.26 from `ubi10/go-toolset`

Both refs use `from: konflux-overlay-install` and `cli: latest` for `oc`.

## Credentials

`konflux-ci-secrets-new` → `/usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/`. Required keys:

| Key | Purpose |
|-----|---------|
| `github-token` | PAT used by the step entrypoints to clone infra-deployments |
| `github_accounts` | Comma-separated `user:token` pairs for GitHub API access |
| `default-quay-org-token` | Quay token for the `redhat-appstudio-qe` org (image-controller) |
| `quay-token` | Base64-encoded Docker config for Quay registry auth |
| `pac-github-app-id` | GitHub App ID for Pipelines-as-Code |
| `pac-github-app-private-key` | GitHub App private key (PEM) for Pipelines-as-Code |
| `pac-github-app-webhook-secret` | Webhook secret for the PAC GitHub App |
| `smee-channel` | Smee.io channel URL for webhook proxying |
| `qe-sprayproxy-host` | SprayProxy server URL |
| `qe-sprayproxy-token` | Bearer token for SprayProxy registration |

## Testing

- **Release PR:** `/pj-rehearse pull-ci-redhat-appstudio-infra-deployments-main-konflux-ring-deployments-conformance-tests`
- **Infra PR:** `/test konflux-ring-deployments-conformance-tests` after openshift/release is merged.
