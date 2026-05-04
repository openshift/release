# Agent-based Installer (ABI)

**Layout (step-registry paths):** `conf/<platform>/` holds manifest / image-input work; `install/<mechanism>/` holds boot and cluster deployment (e.g. **BMC**
virtual media today; **PXE** or other targets can be added alongside without colliding with bare-metal **conf**). See `conf/bm` and `install/bmc` below.

**Step Inputs Parameters (names, defaults, semantics):**
  | Step                | Reference (source of truth)                                           | Registry Documentation                                                        |
  |---------------------|-----------------------------------------------------------------------|-------------------------------------------------------------------------------|
  | **abi-conf-bm**     | [`abi-conf-bm-ref.yaml`](conf/bm/abi-conf-bm-ref.yaml)                | [`abi-conf-bm`](https://steps.ci.openshift.org/reference/abi-conf-bm)         |
  | **abi-install-bmc** | [`abi-install-bmc-ref.yaml`](install/bmc/abi-install-bmc-ref.yaml)    | [`abi-install-bmc`](https://steps.ci.openshift.org/reference/abi-install-bmc) |

**Steps Execution Order:** [`abi-conf-bm-commands.sh`](conf/bm/abi-conf-bm-commands.sh) → [`abi-install-bmc-commands.sh`](install/bmc/abi-install-bmc-commands.sh)

**Official Documentation:** [Preparing to install with the Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-the-agent-based-installer).

## Installation Phases

| Phase         | Comments                                                                                                                                                                                                                                                                                                              |
|---------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Day-0**     | Cluster Configuration.<br> Creates a bare-minimum `install-config.yaml` and generates an `agent-config.yaml` template. Then `UpdateCfg Day0` applies overrides from `OCP__ABI__CFG`, followed by `OCP__ABI__DAY0_SCRIPTS_YAML`. Both configuration files must be complete before proceeding to Day-1.                 |
| **Day-1**     | Manifest Customization.<br> Generates the full manifest tree under `openshift/` (`agent create cluster-manifests`). Then `UpdateCfg Day1` applies overrides from `OCP__ABI__CFG`, followed by `OCP__ABI__DAY1_SCRIPTS_YAML`, before the ISO is built.                                                                 |
| **Day-1.5**   | Post-Bootstrap Operations.<br> Runs after `agent wait-for bootstrap-complete`. Applies custom actions as configured in `OCP__ABI__CFG` (e.g. scale Worker MachineSets to 0 when workers are provisioned directly by ABI). Runs concurrently with `wait-for install-complete`.                                         |
| **Day-2**     | Post-Deployment Customization.<br> Runs after `agent wait-for install-complete` and `KUBECONFIG` is set. Custom post-deployment actions via `OCP__ABI__DAY2_SCRIPTS_YAML` (e.g. install operators, apply policies). Cluster health checked by `cucushift-installer-check-cluster-health` in the workflow, not here.   |

`SHARED_DIR` holds inter-step artifacts (tarball, kubeconfig, `kubeconfig-minimal`). Logs and `ocp.tgz` → `ARTIFACT_DIR`.

## OCP__ABI__CFG

Pre-populate `OCP__ABI__CFG` (`${CLUSTER_PROFILE_DIR}/ocp--abi--cfg.yaml`) with the full `agent-config.yaml`, e.g. Host definitions (NMState network config,
BMC addresses), and any extra configuration needed:
```yaml
Day0:
  config: {}
  configFileOverride:
    yaml+:
      - ...yamlCfg...:
          ...yamlCfgContentToDeepMergeAppendArray...
    yaml-:
      - ...yamlCfg...:
          ...yamlCfgContentToDeepMergeReplaceArray...
    yaml=:
      - ...yamlCfg...:
          ...yamlCfgContentToReplace...
    json+:
      - ...jsonCfg...: |
          ...jsonCfgContentToDeepMergeAppendArray...
    json-:
      - ...jsonCfg...: |
          ...jsonCfgContentToDeepMergeReplaceArray...
    json=:
      - ...jsonCfg...: |
          ...jsonCfgContentToReplace...
Day1:   # Same schema as `Day0`
  ...
Day1.5:
  config:
    - NodeProv: ...booleanNodeProvisioningStatus...
Day2:   # Same schema as `Day1.5`
  ...
```

Example:
```yaml
Day0:
  configFileOverride:
    yaml-:
      - install-config.yaml:
          networking:
            machineNetwork:
              - cidr: 10.6.158.0/24
          platform:
            baremetal:
              apiVIPs:
                - 10.6.158.26
              ingressVIPs:
                - 10.6.158.27
      - agent-config.yaml:  # Full agent-config.yaml: Host definitions (NMState network config, BMC addresses, roles, rootDeviceHints, etc.)
          apiVersion: v1beta1
          kind: AgentConfig
          metadata:
            name: integrity-config
          rendezvousIP: 10.6.158.11
          additionalNTPSources:
            - clock.corp.redhat.com
          hosts:
            - ... # Per-host: hostname, role, rootDeviceHints, interfaces, networkConfig, bmc
Day1.5:
  config:
    - NodeProv: false
```

## Tunneling / Chisel

Operational layout and port table: [WebApp Services — Chisel Tunneling Service](https://redhat.atlassian.net/wiki/spaces/MPEXIENG/pages/254804070/WebApp+Services#Step2.1.2.2.3--Chisel_OperationalTasks).

Step Input Parameters: `OCP__ABI__TUN_SVC__*` / `OCP__ABI__TEAM_NAME`

## BMC / Redfish

**abi-conf-bm** emits `ocp--bmc--info.json`; **abi-install-bmc** drives virtual media and power via Redfish. Details live in `abi-install-bmc-commands.sh`
(maintainer-oriented).

## Phase Customization Scripts

The `OCP__ABI__DAY0_SCRIPTS_YAML`, `OCP__ABI__DAY1_SCRIPTS_YAML`, and `OCP__ABI__DAY2_SCRIPTS_YAML` allow injecting arbitrary shell scripts into the
corresponding installation phase, executed in the order listed within the step's shell environment. See [Installation Phases](#installation-phases) for when
each script runs relative to the phase operations.

Example (`OCP__ABI__DAY0_SCRIPTS_YAML`):
```yaml
OCP__ABI__DAY0_SCRIPTS_YAML: |
  Scripts:
    - | # Complete override of configuration files instead of using `OCP__ABI__CFG` mechanism (not recommended, just serves as an example).
      mkdir -p "${OCP__ABI__CLUSTER_DIR}/openshift"
      cp -f "${CLUSTER_PROFILE_DIR}/install-config.yaml" "${OCP__ABI__CLUSTER_DIR}/install-config.yaml"
      cp -f "${CLUSTER_PROFILE_DIR}/agent-config.yaml" "${OCP__ABI__CLUSTER_DIR}/agent-config.yaml"
```

Schema: [BuildCustomScriptsFromYAML.sh](https://github.com/RedHatQE/OpenShift-LP-QE--Tools/blob/main/libs/bash/common/BuildCustomScriptsFromYAML.sh).
