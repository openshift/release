# AGENTS.md — Guide for AI Coding Agents (agent-sandbox CI config)

Guidance for AI agents working on the **agent-sandbox** `ci-operator`
configuration — pipeline images, releases, and periodic job definitions.

**Scope split** — keep changes in the right place:
- **This file** covers the *config side*: pipeline images, `build_root`,
  `base_images`, `releases`, and the `tests` that wire jobs to workflows.
- Step/chain/workflow authoring lives in
  [`../../../step-registry/agent-sandbox/AGENTS.md`](../../../step-registry/agent-sandbox/AGENTS.md).

Read the repository-root `CLAUDE.md` first for general repo structure.

## File Location & Layout

- This file: `ci-operator/config/openshift/kubernetes-sigs-agent-sandbox/AGENTS.md`
- Generated Prow jobs (never edit by hand): `ci-operator/jobs/openshift/kubernetes-sigs-agent-sandbox/`

Config files follow the naming convention:
```
openshift-kubernetes-sigs-agent-sandbox-main__<variant>.yaml
```

### Config Variants

| Variant | Contents | OCP version |
|---|---|---|
| `__kata-422` | Azure + GCP kata e2e | 4.22 |
| `__kata-421` | Azure + GCP kata e2e | 4.21 |
| `__kata-500` | Azure + GCP kata e2e | 5.0 |
| `__peerpods` | Azure + AWS peer-pods e2e | 4.22 |
| `__standalone` | Azure e2e without OSC (default runtime) | 4.22 |

Kata variants test local kata sandboxes (`SANDBOX_RUNTIME_CLASS=kata`).
Peerpods variants test cloud API adaptor sandboxes (`SANDBOX_RUNTIME_CLASS=kata-remote`).

## Pipeline Images

### `build_root`
All variants use: `rhel-9-golang-1.26-openshift-4.23`

### `releases`
- OCP 4.21 and 4.22: `integration` mode — resolves `upi-installer` automatically
  from the imagestream, no `base_images` needed.
- OCP 5.0: `release` mode with `channel: candidate`, `version: "5.0"` — requires
  explicit `base_images: upi-installer` pointing to `ocp/5.0`.

### Catalog Image
All variants share a single catalog image (`AGENT_SANDBOX_CATALOG_IMAGE`).
When updating, change the image reference in every variant file.

## Scheduling Conventions

Jobs are staggered by weekday to avoid overlapping cluster provisioning:

| Day | Variant |
|---|---|
| Monday | `__kata-422` (OCP 4.22) |
| Tuesday | `__kata-421` (OCP 4.21) |
| Wednesday | `__kata-500` (OCP 5.0) |
| Thursday | `__peerpods` (OCP 4.22) |
| Friday | `__standalone` (OCP 4.22) |

All jobs run at 06:00 UTC. Cron format: `0 6 * * <day>` where day is 1-5.

## Cluster Profiles

| Profile | Used by | Notes |
|---|---|---|
| `openshift-org-azure` | Kata Azure tests | General-purpose, open to openshift org |
| `openshift-org-gcp` | Kata GCP tests | General-purpose, open to openshift org |
| `azure-qe` | Peerpods Azure tests | Shared with SCO; has NAT gateway permissions |
| `aws-sandboxed-containers-operator` | Peerpods AWS tests | Shared with SCO; has IAM/SG permissions |

The peerpods profiles are shared quota pools with the sandboxed-containers-operator
team. Profile ownership for this repo is pending approval in a separate PR.

## Adding a New OCP Version

1. Copy an existing kata variant file and rename with the version suffix
   (e.g., `__kata-510.yaml`)
2. Update `releases.latest` to the target version
3. For OCP 5.0+: use `release` mode and add `base_images: upi-installer`
4. Stagger cron to an unused weekday
5. Run `make update`

## Verify Changes

```bash
make ci-operator-config    # determinize config formatting
make jobs                  # generate Prow jobs + checkconfig validation
```
