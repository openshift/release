# CNV VM Upgrade Survival Check

## What this step does?

Verifies that CNV test VirtualMachines created before the OCP upgrade have survived the upgrade and are still running.

1. Loops through all VMs created by `p2p-create-migration-test-vm` (test-vm-1 through test-vm-N)
2. Checks that each VM resource still exists
3. Verifies each VMI (running instance) is in Running phase
4. Reports pass/fail per VM and overall results

## Requirements

1. Container image with `oc` CLI available (from: cli)
2. Spoke kubeconfig at `${SHARED_DIR}/managed-cluster-kubeconfig`
3. VMs pre-created by `p2p-create-migration-test-vm` step in the same namespace

## Environment Variables

- `CNV_TEST_VM_COUNT`: Number of VMs to verify (default: 1, must match creation count)
- `CNV_TEST_VM_NAMESPACE`: Namespace containing the test VMs (default: vm-migration-test)

## Typical Usage in Workflow

```
p2p-create-migration-test-vm (creates 5 VMs: test-vm-1 .. test-vm-5)
  ↓
  [OCP hub and spoke upgrades]
  ↓
p2p-cnv-upgrade-survival-check (verifies all 5 VMs survived)
```
