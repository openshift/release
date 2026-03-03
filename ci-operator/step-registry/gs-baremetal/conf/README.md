# gs-baremetal-conf (Day 0)

Generates `install-config.yaml` and `agent-config.yaml` for the Agent-Based Installer (ABI) with **static networking** (NMState) suitable for OCP 4.19 and RDU2 lab.

## Inputs

- **SHARED_DIR/hosts.yaml** (required): List of hosts. Each entry must include:
  - `name`: hostname (e.g. `master-0`, `worker-0`)
  - `mac`: MAC address of the primary interface
  - `ip`: static IPv4 address
  - `baremetal_iface` or `interface`: interface name (default `eth0`)
  - `prefix_length` or `prefix-length`: optional; otherwise derived from `INTERNAL_NET_CIDR` or default 24
  - Optional for later steps: `host`/`bmc_address`, `bmc_user`, `bmc_password` for BMC access

- **Cluster profile** (e.g. `metal-redhat-gs`): must provide `base_domain` and `pull-secret`. Optional: `cluster_name`.

- **SHARED_DIR/cluster_name**: optional; if set (e.g. by `ipi-conf`), used as cluster name.

## Outputs

- **SHARED_DIR/install-config.yaml**: platform `none`, baseDomain, pullSecret, controlPlane/compute replicas.
- **SHARED_DIR/agent-config.yaml**: `apiVersion: v1beta1`, `kind: AgentConfig`, `rendezvousIP` (first host’s IP), optional `additionalNTPSources`, and `hosts[]` with NMState (interface, static ipv4, optional dns-resolver and routes).

## Environment variables

See `gs-baremetal-conf-ref.yaml`: `CLUSTER_NAME`, `BASE_DOMAIN`, `NTP_SOURCES`, `INTERNAL_NET_GW`, `INTERNAL_NET_DNS`, and default `INTERNAL_NET_CIDR` (192.168.80.0/22) for prefix when not per-host.

## Workflow order

Run after `hosts.yaml` is available (e.g. from a step that populates it from BitWarden or cluster profile). Run before the step that executes `openshift-install agent create image` and before `gs-baremetal-orchestrate`.
