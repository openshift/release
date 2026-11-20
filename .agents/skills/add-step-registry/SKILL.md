---
name: add-step-registry
description: >-
  Add a new step-registry step (ref YAML + commands.sh) in openshift/release.
  Use when creating a new CI step, atomic test action, or reusable ref component.
  Run step-finder first to avoid duplicates.
---
# Add Step Registry Step

Create a new atomic step under `ci-operator/step-registry/`.

## Before you start

1. Run **step-finder** (or `python3 .claude/scripts/step_finder.py "<query>"`) — reuse existing steps when possible.
2. Read a similar step in the same area for `from`, env vars, credentials, and script patterns.
3. Confirm the step belongs in step-registry (single task), not a one-off inline in one repo's config.

## Scaffold files

Dry-run (prints target paths to stderr; add `--preview` to show generated bodies):

```bash
python3 .claude/scripts/scaffold_step_registry.py \
  --name <step-name> \
  --subdir <path-under-step-registry> \
  --from cli \
  --documentation "What this step does"
```

ImageStream-based step (uses `from_image` block instead of `from` alias):

```bash
python3 .claude/scripts/scaffold_step_registry.py \
  --name <step-name> \
  --subdir <path-under-step-registry> \
  --from-image-namespace <ns> \
  --from-image-name <name> \
  --from-image-tag <tag> \
  --write
```

Create files:

```bash
python3 .claude/scripts/scaffold_step_registry.py \
  --name <step-name> \
  --subdir <path-under-step-registry> \
  --from cli \
  --documentation "What this step does" \
  --write
```

Naming:

| Item | Rule |
|------|------|
| `--name` | lowercase, hyphens; becomes `ref.as` and `ref: <name>`; must not end with `-step` |
| files | `<name>-ref.yaml`, `<name>-commands.sh` |
| `--subdir` | e.g. `myorg/install` → `ci-operator/step-registry/myorg/install/` |

Common `from` alias values: `cli`, `tests`, or another image alias from the consuming repo's ci-operator config. Use `--from-image-*` when the step needs an explicit ImageStream reference.

## Implement the step

1. Edit `*-commands.sh`:
   - Start with `set -euo pipefail` (avoid `-x` unless debugging).
   - Disable tracing around secrets/passwords (see root `AGENTS.md`).
   - Use `${SHARED_DIR}` to pass data between steps; do not echo credentials.
2. Edit `*-ref.yaml`:
   - Add `env` entries with `default` + `documentation` for tunables.
   - Set `timeout`, `grace_period`, `resources` if non-default.
   - Add `dependencies` / `credentials` only when required (copy from similar steps).
3. Add `OWNERS` under new top-level directories if no parent OWNERS covers the path.

## Validate and regenerate

For a registry-only change, regenerate metadata, validate the config and
registry, and regenerate and validate Prow jobs. Registry changes can affect
generated Prow jobs, for example when a workflow's inherited cluster profile
changes generated cloud/profile labels:

```bash
make registry-metadata
make validate-step-registry
make jobs
make checkconfig
```

If the same PR also edits a ci-operator config, use this instead of the
standalone commands above:

```bash
make update
make checkconfig
```

`make update` includes config/registry validation and metadata generation. For
details on these validation targets, see the root AGENTS.md sections on
[CI Job Configuration](../../../AGENTS.md#ci-job-configuration) and
[Step Registry Validation](../../../AGENTS.md#step-registry-validation).
The `ci/prow/step-registry-metadata` presubmit checks that generated metadata is
current.

## Wire into a test (same or follow-up PR)

In `ci-operator/config/<org>/<repo>/<branch>.yaml`:

```yaml
tests:
- as: my-test
  steps:
    pre:
    - ref: <step-name>
    test:
    - ref: openshift-e2e-test
```

Or reference the step from a `-chain.yaml` / `-workflow.yaml` instead of directly in config.

## Chains and workflows

This skill scaffolds **steps** only. For chains/workflows:

- **Chain**: new `*-chain.yaml` listing `- ref:` / `- chain:` steps; no commands script.
- **Workflow**: new `*-workflow.yaml` with `pre` / `test` / `post` phases.

Copy structure from an existing chain/workflow in the same platform area. For a
chain-only or workflow-only change, use the same step-registry validation and
Prow job commands listed above.

## Checklist

- [ ] step-finder searched; no duplicate
- [ ] `-ref.yaml` + `-commands.sh` created and named consistently
- [ ] documentation field describes behavior
- [ ] secrets handled safely in shell
- [ ] For a registry-only change, run `make registry-metadata`,
      `make validate-step-registry`, `make jobs`, and `make checkconfig`
- [ ] If the registry change also edits a ci-operator config, run
      `make update` and `make checkconfig`
- [ ] referenced from config/chain/workflow if intended for use
