# gs-baremetal-fetch-hosts (Day 0)

Copies the host list from a credential mount into **SHARED_DIR/hosts.yaml** for use by `gs-baremetal-conf` and `gs-baremetal-orchestrate`. First step in the Day 0 preparation sequence.

## When to use

Use when host/BMC data lives in a **credential** (e.g. BitWarden-backed vault) rather than the cluster profile. Run this as the **first pre-step** before `gs-baremetal-conf`.

## BitWarden (RDU2 lab)

Cluster and BMC information may be stored in a **BitWarden note**. The note’s **BMC** field typically holds the host/BMC list. To use it in CI:

1. **Locally**: Fetch the BMC value and save it as YAML in the expected format:
   ```bash
   bw get item "<BITWARDEN_NOTE_NAME>" | jq -r '.fields[] | select(.name == "BMC").value' > hosts.yaml
   ```
   Replace `<BITWARDEN_NOTE_NAME>` with the note name configured for your lab (e.g. from internal runbooks or cluster profile docs).
2. **Store** `hosts.yaml` in the credential used by the job (e.g. add it to the vault that mounts at `/bw` so the file is at `/bw/hosts.yaml`).
3. The workflow uses **credentials** that mount that vault; this step copies the file to SHARED_DIR.

## hosts.yaml format

Must be a YAML **array** of host objects. Each object must have:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Hostname (e.g. `master-0`, `worker-0`). Role is derived from prefix. |
| `mac` | yes | MAC address of the primary interface. |
| `ip` | yes | Static IPv4 address (first host’s IP is used as rendezvousIP). |
| `host` or `bmc_address` | for orchestrate | BMC address for Redfish/IPMI. |
| `bmc_user` | optional | BMC user (default `root`). |
| `bmc_password` | optional | BMC password for Redfish/IPMI. |
| `baremetal_iface` / `interface` | optional | Interface name (default `eth0`). |
| `prefix_length` / `prefix-length` | optional | IPv4 prefix length; else derived from INTERNAL_NET_CIDR. |

Example:

```yaml
- name: master-0
  mac: aa:bb:cc:dd:ee:01
  ip: 192.168.80.11
  host: bmc-master-0.example.com
  bmc_user: root
  bmc_password: secret
- name: master-1
  mac: aa:bb:cc:dd:ee:02
  ip: 192.168.80.12
  host: bmc-master-1.example.com
  bmc_user: root
  bmc_password: secret
# ... more hosts
```

## Inputs

- **Credential mount**: Directory containing `hosts.yaml` (e.g. `BW_PATH` default `/bw`).
- **HOSTS_SOURCE_PATH** (optional): Full path to the hosts file. If set, overrides `BW_PATH/hosts.yaml`.

## Outputs

- **SHARED_DIR/hosts.yaml**: Host list for conf and orchestrate steps.

## Workflow order

Use as the **first** pre-step in the gs-baremetal-agent-install workflow, before `gs-baremetal-conf`.
