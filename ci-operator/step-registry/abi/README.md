# Agent-based Installer (ABI) — `abi` step registry

**Step inputs (names, defaults, semantics):** each step’s **`*-ref.yaml`** `env` section — the canonical copy in-repo, also published on the Step Registry (search by step name).

| Step | Ref (source of truth) | Registry |
|------|------------------------|----------|
| **abi-bm-conf** | [`bm/conf/abi-bm-conf-ref.yaml`](bm/conf/abi-bm-conf-ref.yaml) | [`abi-bm-conf`](https://steps.ci.openshift.org/reference/abi-bm-conf) |
| **abi-bm-install** | [`bm/install/abi-bm-install-ref.yaml`](bm/install/abi-bm-install-ref.yaml) | [`abi-bm-install`](https://steps.ci.openshift.org/reference/abi-bm-install) |

**Implementation (order of operations, Redfish calls, traps):** [`bm/conf/abi-bm-conf-commands.sh`](bm/conf/abi-bm-conf-commands.sh), [`bm/install/abi-bm-install-commands.sh`](bm/install/abi-bm-install-commands.sh). Prefer updating **refs** for parameter docs so this README does not need to track every script change.

Product docs: [Preparing to install with the Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-the-agent-based-installer).

## Phases (overview)

| | |
|--|--|
| **Day-0** | `install-config` / `agent-config` → **`openshift-install create install-config`** → **OCP__ABI__DAY0_SCRIPTS_YAML** |
| **Day-1** | **`openshift-install agent create cluster-manifests`** → **OCP__ABI__DAY1_SCRIPTS_YAML** |
| **Handoff** | **abi-bm-conf** writes **`${SHARED_DIR}/ocpClusterInf.tgz`**; **abi-bm-install** unpacks, **`agent create image`**, … |
| **Day-2** | After **`install-complete`**: kubeconfig to **`SHARED_DIR`**; **`KUBECONFIG`** under **`${OCP__ABI__CLUSTER_DIR}/auth/kubeconfig`** → nodes Ready → **OCP__ABI__DAY2_SCRIPTS_YAML** (cluster health: **`cucushift-installer-check-cluster-health`** in the workflow, not in this step) |

**`SHARED_DIR`** holds inter-step artifacts (tarball, kubeconfig, **`kubeconfig-minimal`**). Logs and **`ocp.tgz`** → **`ARTIFACT_DIR`**.

## Chisel / tunneling (interop)

Operational layout and port table: [WebApp Services — Chisel Tunneling Service](https://redhat.atlassian.net/wiki/spaces/MPEXIENG/pages/254804070/WebApp+Services#Chisel-Tunneling-Service). Job-facing **`OCP__ABI__TUN_SVC__*`** / **`OCP__ABI__TEAM_NAME`** semantics: **`abi-bm-install-ref.yaml`** (not duplicated here).

## BMC / Redfish

**abi-bm-conf** emits **`bmc--info.json`**; **abi-bm-install** drives virtual media and power via Redfish. Details live in **`abi-bm-install-commands.sh`** (maintainer-oriented).

## Example: Day0 scripts

```yaml
OCP__ABI__DAY0_SCRIPTS_YAML: |
  Scripts:
    - |
      mkdir -p "${OCP__ABI__CLUSTER_DIR}/openshift"
      cp -f "${CLUSTER_PROFILE_DIR}/install-config.yaml" "${OCP__ABI__CLUSTER_DIR}/install-config.yaml"
      cp -f "${CLUSTER_PROFILE_DIR}/agent-config.yaml" "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"
```

Schema: [BuildCustomScriptsFromYAML.sh](https://github.com/RedHatQE/OpenShift-LP-QE--Tools/blob/main/libs/bash/common/BuildCustomScriptsFromYAML.sh).

## Workflows

- **gs-baremetal** — [`../gs-baremetal/README.md`](../gs-baremetal/README.md), job env index [`../gs-baremetal/CI-ABI-JOB-CONFIG.md`](../gs-baremetal/CI-ABI-JOB-CONFIG.md)
