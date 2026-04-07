# ABI bare-metal job env contract (interop)

Jobs using workflow `gs-baremetal-agent-install` (variant e.g. `gs-bm--ocp-4.19--lp-interop`) set **`OCP__ABI_*`** in Job Conf. YAML **`.tests[*].steps.env`**.

**Semantics and defaults:** step **`*-ref.yaml`** files (published on the Step Registry: [`abi-bm-conf`](https://steps.ci.openshift.org/reference/abi-bm-conf), [`abi-bm-install`](https://steps.ci.openshift.org/reference/abi-bm-install)). **Chisel / NGINX** topology and port table: [WebApp Services — Chisel Tunneling Service](https://redhat.atlassian.net/wiki/spaces/MPEXIENG/pages/254804070/WebApp+Services#Chisel-Tunneling-Service).

| Env                              | Step that consumes it           | Source of truth |
|----------------------------------|---------------------------------|-----------------|
| `OCP__ABI__BM__CLS_NAME`         | `abi-bm-conf`                 | [`abi-bm-conf-ref.yaml`](../abi/bm/conf/abi-bm-conf-ref.yaml) |
| `OCP__ABI__BM__BASE_DOM`         | `abi-bm-conf`                 | [`abi-bm-conf-ref.yaml`](../abi/bm/conf/abi-bm-conf-ref.yaml) |
| `OCP__ABI__DAY0_SCRIPTS_YAML`    | `abi-bm-conf`                 | [`abi-bm-conf-ref.yaml`](../abi/bm/conf/abi-bm-conf-ref.yaml) |
| `OCP__ABI__DAY1_SCRIPTS_YAML`    | `abi-bm-conf`                 | [`abi-bm-conf-ref.yaml`](../abi/bm/conf/abi-bm-conf-ref.yaml) |
| `OCP__ABI__CLUSTER_DIR`          | `abi-bm-conf`, `abi-bm-install` | [`abi-bm-conf-ref.yaml`](../abi/bm/conf/abi-bm-conf-ref.yaml), [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__INSTLR_LOG_LEVEL`     | `abi-bm-conf`, `abi-bm-install` | [`abi-bm-conf-ref.yaml`](../abi/bm/conf/abi-bm-conf-ref.yaml), [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__WAIT__BOOTSTRAP__H`    | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__WAIT__CLUSTER__H`      | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__DAY2_SCRIPTS_YAML`    | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__TEAM_NAME`            | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__TUN_SVC__DP_BASE_URL` | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__TUN_SVC__DP_PORT`     | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |
| `OCP__ABI__TUN_SVC__CP_URL`      | `abi-bm-install`              | [`abi-bm-install-ref.yaml`](../abi/bm/install/abi-bm-install-ref.yaml) |

YAML script schema (DAY0/DAY1/DAY2 hooks): [BuildCustomScriptsFromYAML.sh](https://github.com/RedHatQE/OpenShift-LP-QE--Tools/blob/HEAD/libs/bash/common/BuildCustomScriptsFromYAML.sh).

**Test phase:** Workflow `gs-baremetal-agent-install` defines only `pre` and `post`. The job must define `steps.test` (e.g. `chain: cucushift-installer-check-cluster-health`). If the job sets `test`, it replaces the workflow’s test section for that job.

See also [README.md](./README.md) and [ABI overview](../abi/README.md).
