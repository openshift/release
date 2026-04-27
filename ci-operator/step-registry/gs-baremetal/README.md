# gs-baremetal

CI workflows for **Agent-based Installer (ABI)** on bare metal in RDU2 (**`metal-redhat-gs`**) without a bastion.

**ABI behavior (phases, pointers):** **[`../abi/README.md`](../abi/README.md)** — step parameters live in **`abi/conf/bm/*-ref.yaml`**, **`abi/install/bmc/*-ref.yaml`**, and the Step Registry; implementation detail in the matching **`*-commands.sh`** files.

## Workflow `gs-baremetal-agent-install`

- **Test:** not defined on the workflow; the job must set **`steps.test`** (e.g. `chain: cucushift-installer-check-cluster-health`).
- **Env:** set **`steps.env`** per the **`abi-conf-bm`** / **`abi-install-bmc`** **`*-ref.yaml`** files (see [`../abi/README.md`](../abi/README.md)); a consolidated job env table is planned in a follow-up change.
- **Cluster profile:** **`metal-redhat-gs`** (fixed by this workflow).
- **Capability:** **`intranet`** (standard for GS bare-metal jobs that reach internal services).

Definition: [`agent-install/gs-baremetal-agent-install-workflow.yaml`](agent-install/gs-baremetal-agent-install-workflow.yaml)

Red Hat product docs for manifests and installer commands (**latest** doc stream): [Preparing to install with the Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer) (also linked from [`../abi/README.md`](../abi/README.md)).
