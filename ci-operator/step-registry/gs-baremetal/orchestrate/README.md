# gs-baremetal-orchestrate

## Purpose

Orchestrates **Agent-Based Installation (ABI)** of OpenShift on bare metal in the RDU2 lab **without a bastion**. The CI Pod acts as the control plane: it hosts the agent ISO via an HTTP server in the pod, talks directly to BMCs (Redfish/IPMI), and runs `openshift-install agent wait-for install-complete`.

## Architecture (high level)

- **Existing** `gs-baremetal-localnet-test` runs tests against an **already installed** cluster (`workflow: external-cluster`). It does **not** install the cluster.
- **New** workflow adds **Day 0 → Day 1 → Day 2** steps to **install** OCP via ABI on RDU2 hardware.

| Phase   | Operation              | Implementation |
|--------|-------------------------|----------------|
| **Day 0** | Configuration + image   | Fetch hosts; generate `install-config.yaml` and `agent-config.yaml` ( **gs-baremetal-conf** ); create agent ISO ( **gs-baremetal-create-image** ). |
| **Day 1** | Boot and install        | Host the ISO in the CI Pod; mount via BMC virtual media and power on nodes ( **gs-baremetal-orchestrate** ). Same step optionally runs `wait-for install-complete` and exports kubeconfig. |
| **Day 2** | Post-install            | Optional: add nodes, gather artifacts, run tests (e.g. **cucushift-installer-check-cluster-health** ). |

## Role of gs-baremetal-orchestrate

This step implements the **Day 1** “last mile” when there is **no AUX_HOST**:

1. **Host the ISO**  
   Make the agent ISO reachable by the bare metal nodes (an HTTP server in the pod serves the ISO directory so nodes can pull it via the pod IP and port).

2. **BMC control**  
   For each host in `hosts.yaml`, use Redfish (curl) or IPMI (ipmitool) from the CI Pod to:
   - Mount the ISO URL as virtual media
   - Set boot device to CD/virtual media
   - Power cycle the node

3. **Optional**  
   Same step (or a dedicated next step) can run `openshift-install agent wait-for install-complete` and copy kubeconfig to `SHARED_DIR`.

Existing steps (e.g. `agent-qe-baremetal-install-ove`) assume an **AUX_HOST**: they SSH to it to run `mount.vmedia` and `prepare_host_for_boot`. For RDU2 with no bastion, that logic is replaced by **direct** BMC access from the pod; gs-baremetal-orchestrate encapsulates that.

## Workflow integration

The **new workflow** (e.g. `gs-baremetal-agent-install`) composes:

- **Pre**
  - Day 0: fetch hosts ( **gs-baremetal-fetch-hosts** ); config ( **gs-baremetal-conf** ); create image ( **gs-baremetal-create-image** ).
  - Day 1: **gs-baremetal-orchestrate** — host ISO, direct BMC mount and power on; optionally run `wait-for install-complete` and export kubeconfig.
- **Test**
  - Cluster health (e.g. **cucushift-installer-check-cluster-health** ); kubeconfig comes from orchestrate when it runs wait-for.
- **Post**
  - Day 2: optional post-install logic; gather artifacts.

Cluster profile **metal-redhat-gs** and **intranet** capability are used so the CI Pod can reach RDU2 BMCs and nodes.

## Dependencies

- **Inputs**: `SHARED_DIR` must contain:
  - `hosts.yaml` (per-host entries with BMC address, credentials, and optional `transfer_protocol_type`).
  - Agent ISO (e.g. `agent.x86_64.iso`) or the path where it was built (e.g. under an install dir).
- **Cluster profile**: `metal-redhat-gs` (provides secrets/SSH and lab-specific data as configured).
- **Image**: Must have `ipmitool`, `curl`, `jq`, `yq`, and a way to serve the ISO (the script uses `python3 -m http.server`).

## Environment variables

See `gs-baremetal-orchestrate-ref.yaml` for `AGENT_ISO`, `BOOT_MODE`, `HTTP_PORT`, and `POD_IP`.

## Redfish URI variability

Redfish virtual-media paths differ by vendor (e.g. Dell iDRAC, HP iLO, Supermicro). The orchestrate script uses a generic path (`/redfish/v1/Managers/1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia`). If your RDU2 hardware uses a different path, set **BMC_TYPE** (e.g. `dell`, `hp`, `supermicro`) in the job env and extend the script to try vendor-specific URIs, or add a small discovery block that queries `GET /redfish/v1/Managers/1/VirtualMedia` and uses the first available InsertMedia action.
