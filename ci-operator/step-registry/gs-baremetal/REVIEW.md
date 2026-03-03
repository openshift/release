# Bare metal deployment review (release repo)

**Purpose:** This file is **documentation only** — not read by CI. Use it when:
- **Reviewing PRs** to gs-baremetal: check that steps follow the patterns below and the improvements are preserved.
- **Adding or changing steps**: follow the same patterns so gather/must-gather and downstream jobs keep working; avoid reintroducing the typos used elsewhere (e.g. `virtual_media_mount_failed` vs `virtual_media_mount_failure`).
- **Running or debugging the job**: see "Workflow and CI" and the **hosts.yaml** requirement.

---

Summary of patterns from existing bare metal steps/workflows and improvements applied to the gs-baremetal steps.

## Existing patterns (release repo)

### baremetal-lab / agent-qe

- **install-status.txt**: Written on TERM/ERR (and sometimes EXIT) so gather/must-gather and junit can use it. Example: `trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR`
- **host-id.txt**: First host’s BMC id (`.[0].host`) in SHARED_DIR for gather steps that need a single host.
- **Virtual media failure**: Scripts touch `/tmp/virtual_media_mount_failure` on mount failure; downstream they check for `/tmp/virtual_media_mount_failed` (typo in repo: touch and check use different filenames, so the check never triggers). Use one name consistently for both.
- **oinst wrapper**: `openshift-install` output is piped through `grep -v 'password|X-Auth-Token|UserData:'` to avoid leaking secrets.
- **Timeouts**: Long operations use `timeout -s 9 10m` for SSH/BMC; refs use `timeout` (e.g. 2h) and `grace_period: 600`.
- **proxy-conf.sh**: Lab steps source `${SHARED_DIR}/proxy-conf.sh` when present (proxy environments).
- **cluster_name**: Written to SHARED_DIR for downstream steps; often read from ipi-conf or cluster profile.
- **Patch files**: install-config and agent-config can be patched via `*_patch_install_config.yaml` and `*_patch_agent_config.yaml` in SHARED_DIR.

### Ref YAML

- **timeout**: Long-running install steps set e.g. `timeout: 2h0m0s`.
- **grace_period**: 600 is common for agent/bare metal install steps.
- **dependencies**: `release:latest` → `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` when the step runs the installer.

## Improvements applied to gs-baremetal

### gs-baremetal-orchestrate

- **install-status.txt**: Trap on TERM/ERR writes exit code; success path writes 0 when wait-for is not run; mount failure and wait-for failure write non-zero and exit.
- **host-id.txt**: First host’s `host` or `bmc_address` written to SHARED_DIR for gather compatibility.
- **Virtual media failure**: Touch `virtual_media_mount_failure` when Redfish mount fails; after `wait` check for that file and exit 1 (single filename for both).
- **wait-for**: Output piped through `grep -v 'password|...'`; exit code from pipeline used to set install-status and exit (no `|| true` so job fails on install failure).
- **timeout**: Ref now has `timeout: 2h0m0s`.

### gs-baremetal-conf

- **errtrace**: `set -o errtrace` for consistent trap behavior.
- **cluster_name**: Written to `${SHARED_DIR}/cluster_name` for downstream (create image, etc.).
- **masters/workers**: Counts derived from hosts.yaml (by role prefix master/worker); fallback 3 masters, 2 workers if none found.

## Note on existing lab scripts

In `baremetal-lab` and `agent-qe`, the virtual media failure file is created as `virtual_media_mount_failure` but checked as `virtual_media_mount_failed`. Fixing that in the main lab steps would require a separate repo-wide change; gs-baremetal uses `virtual_media_mount_failure` for both touch and check.

## Workflow and CI

- **Day 0 / Day 1 / Day 2**: fetch-hosts and conf and create-image are **Day 0** (prep); orchestrate is **Day 1** (boot + optional wait-for); test and post are **Day 2** (post-install). Script headers and ref/README docs use this terminology.
- **gs-baremetal-agent-install** workflow wires: **gs-baremetal-fetch-hosts** → **gs-baremetal-conf** → **gs-baremetal-create-image** → **gs-baremetal-orchestrate**, then `cucushift-installer-check-cluster-health`. Cluster profile: `metal-redhat-gs`; capability: `intranet`.
- **hosts.yaml**: Fetched by **gs-baremetal-fetch-hosts** from a credential mount (default `/bw/hosts.yaml`). Store the BitWarden note BMC field content as `hosts.yaml` in the vault (see fetch-hosts README for format and note name). Or add `hosts.yaml` to cluster profile and skip fetch-hosts.
- A test entry **gs-baremetal-agent-install-ocp419** in `RedHatQE/interop-testing` uses this workflow so the job is generated once `make update` is run.
