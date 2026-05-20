# gs-baremetal

Step-registry components for **Goldman Sachs** bare-metal CI on cluster profile **`metal-redhat-gs`**.

## Contents of this directory

| Registry name | Path | Role |
|---------------|------|------|
| **gs-baremetal-localnet-test** | [`localnet-test/`](localnet-test/) | OpenShift Virtualization **localnet** tests on a cluster that is **already installed** |

See [`localnet-test/README.md`](localnet-test/README.md) for test prerequisites and env vars.

## ABI cluster provisioning (not in `gs-baremetal/`)

Installing a cluster with the Agent-based Installer (bare metal, BMC virtual media) is defined under **[`../abi/`](../abi/README.md)**:

- Steps: **abi-conf-bm**, **abi-install-bmc**
- Chain: **abi-chains-bm--bmc**
- Workflow: **abi-workflows-bm--bmc--cluster-health** (install + cluster health in **pre**; jobs set **`steps.test`** for product tests)

## CI job configuration

Interop jobs for GS bare metal live under `ci-operator/config/RedHatQE/interop-testing/`:

| Variant | Jobs |
|---------|------|
| `gs-baremetal-localnet-ocp4.19-lp-gs` | **external-cluster** + **gs-baremetal-localnet-test** (pre-installed cluster) |
| `gs-baremetal-ocp4.20-lp-gs` | **abi-workflows-bm--bmc--cluster-health** install-only; same workflow + **gs-baremetal-localnet-test** in **test** |
