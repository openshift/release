# Runtime contract wrappers

These are standalone, no-network contract wrappers for the Quay legacy upgrade
steps. They are intentionally outside `ci-operator/step-registry`: a file
there named `*-commands.sh` is a registry component input and must have a
matching `*-ref.yaml`.

Run them from the repository root:

```bash
bash ci-operator/config/quay/quay/_generator/tests/runtime-contracts/test_upgrade_install_source_runtime_contract.sh
bash ci-operator/config/quay/quay/_generator/tests/runtime-contracts/test_upgrade_legacy_state_runtime_contract.sh
```

They use generated local mocks only. They do not contact a cluster or registry.
