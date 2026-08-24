# Medik8s CI Configs

CI operator configurations for [Medik8s](https://github.com/medik8s) operators.

## Repos

| Directory | Repo | Type |
|-----------|------|------|
| `fence-agents-remediation` | [medik8s/fence-agents-remediation](https://github.com/medik8s/fence-agents-remediation) | Platform-aligned operator |
| `machine-deletion-remediation` | [medik8s/machine-deletion-remediation](https://github.com/medik8s/machine-deletion-remediation) | Platform-aligned operator |
| `node-healthcheck-operator` | [medik8s/node-healthcheck-operator](https://github.com/medik8s/node-healthcheck-operator) | Platform-aligned operator |
| `node-maintenance-operator` | [medik8s/node-maintenance-operator](https://github.com/medik8s/node-maintenance-operator) | Platform-aligned operator |
| `self-node-remediation` | [medik8s/self-node-remediation](https://github.com/medik8s/self-node-remediation) | Platform-aligned operator |
| `storage-based-remediation` | [medik8s/storage-based-remediation](https://github.com/medik8s/storage-based-remediation) | Platform-aligned operator |
| `customized-user-remediation` | [medik8s/customized-user-remediation](https://github.com/medik8s/customized-user-remediation) | Community operator |
| `must-gather` | [medik8s/must-gather](https://github.com/medik8s/must-gather) | Support tooling |
| `node-remediation-console` | [medik8s/node-remediation-console](https://github.com/medik8s/node-remediation-console) | Console plugin |
| `system-tests` | [medik8s/system-tests](https://github.com/medik8s/system-tests) | Integration tests |
| `common` | — | Shared configs and scripts |

## Config naming

Platform-aligned operators use versioned configs:

```
medik8s-{repo}-{branch}__{ocp_version}.yaml
```

For example: `medik8s-fence-agents-remediation-main__4.23.yaml`

Non-OCP-versioned repos (must-gather, node-remediation-console, common) use:

```
medik8s-{repo}-{branch}.yaml
```

After any config change, run `make jobs` from the repo root to regenerate Prow
job definitions under `ci-operator/jobs/`.

## Common scripts

Helper scripts in `common/` for managing CI configs.

### new-ocp-version.sh

Creates versioned config files (`__<ocp_version>.yaml`) for a new OCP version.
Automatically updates `OPERATOR_RELEASED_VERSION` from the latest GitHub release
tag for repos that use it. Only affects repos that already have versioned configs;
non-versioned repos (must-gather, node-remediation-console, common) are skipped.

<!-- TODO: node-remediation-console is installed and deployed with
     node-healthcheck-operator downstream — should it have per-OCP
     versioned lanes as well? -->

```bash
cd ci-operator/config/medik8s/common
./new-ocp-version.sh <OCP_VERSION>
# Example: ./new-ocp-version.sh 5.1
```

### new-release.sh

Creates a config for a new release branch from the latest main config.

```bash
cd ci-operator/config/medik8s/common
./new-release.sh <repo> <branch> [operator_released_version]
# Example: ./new-release.sh fence-agents-remediation release-0.9 0.8.0
```

The third argument sets `OPERATOR_RELEASED_VERSION` for upgrade testing on the
release branch. If omitted, the value from the main config is copied as-is.

### OPERATOR_RELEASED_VERSION

Platform-aligned operators (FAR, NMO, SNR) use this value to:

1. Install the released version via `bundle-run`
2. Upgrade to the latest (from source) via `bundle-run-update`
3. Run e2e tests

Check the latest release tags:
- https://github.com/medik8s/fence-agents-remediation/releases
- https://github.com/medik8s/node-maintenance-operator/releases
- https://github.com/medik8s/self-node-remediation/releases

## References

- [Operator support matrix](https://access.redhat.com/support/policy/updates/openshift_operators#platform-aligned)
- [ci-operator docs](https://docs.ci.openshift.org/docs/architecture/ci-operator/)
- [Branch protection config](../../../../core-services/prow/02_config/medik8s/_prowconfig.yaml)
