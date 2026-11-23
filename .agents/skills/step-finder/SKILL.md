---
name: step-finder
description: >-
  Search openshift/release step-registry for existing steps, workflows, and chains
  before creating new CI components. Use when adding tests, jobs, or step-registry
  entries, or when asked to find reusable pre/test/post components.
---
# Step Registry Search

Search 4,400+ step-registry components before creating duplicates.

## When to use

- Adding a CI test or job that needs `ref`, `chain`, or `workflow`
- Creating a new step-registry component
- Checking blast radius before editing an existing step

## Run the search script

From repo root:

```bash
python3 .claude/scripts/step_finder.py "<query>" [--type step|workflow|chain|all] [--show-usage] [--no-reverse-deps] [--limit N]
```

Examples:

```bash
python3 .claude/scripts/step_finder.py "aws upgrade" --type workflow
python3 .claude/scripts/step_finder.py "install operator" --type step --show-usage
python3 .claude/scripts/step_finder.py openshift-e2e-test --no-reverse-deps
```

All query tokens must match (name, path, or documentation).

## After results

1. Read the YAML and `*-commands.sh` for top matches — do not guess behavior.
2. Prefer reuse over new steps/workflows/chains.
3. Reference in `ci-operator/config/<org>/<repo>/`:
   - step → `- ref: <name>`
   - chain → `- chain: <name>`
   - workflow → `workflow: <name>`
4. Regenerate artifacts: `make update`. It runs `ci-operator-checkconfig`
   through `make jobs`.
5. Validate generated Prow configuration: `make checkconfig`.

For details on these validation targets, see the root AGENTS.md sections on
[CI Job Configuration](../../../AGENTS.md#ci-job-configuration) and
[Step Registry Validation](../../../AGENTS.md#step-registry-validation).

## Component types

| Type | Files | Config reference |
|------|-------|------------------|
| step | `*-ref.yaml` + `*-commands.sh` | `ref:` |
| chain | `*-chain.yaml` | `chain:` |
| workflow | `*-workflow.yaml` (`pre`/`test`/`post`) | `workflow:` |

## Impact from reverse deps

- **HIGH** (100+): coordinate changes carefully
- **MEDIUM** (10–99): test widely used components thoroughly
- **LOW** (1–9): limited usage
- **NONE** (0): top-level workflow or unused

## Do not duplicate

Always run this skill before adding step-registry files. If a close match exists, extend it with env vars or compose it in a chain/workflow instead of copying.
