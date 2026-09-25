# Operator overlay OpenShift CI steps

Optional job `appstudio-operator-overlay-e2e-tests` exercises the **development-operator**
overlay on infra-deployments (not legacy `appstudio-e2e-tests` / `development` preview).

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

`konflux-ci-secrets-new` → `/usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/` (see `konflux-ci-install-konflux` README for keys).

## Testing

- **Release PR:** `/pj-rehearse pull-ci-redhat-appstudio-infra-deployments-main-appstudio-operator-overlay-e2e-tests`
- **Infra PR:** `/test appstudio-operator-overlay-e2e-tests` after openshift/release is merged.
