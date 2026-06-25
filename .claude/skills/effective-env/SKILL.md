---
name: effective-env
description: >-
  Resolve effective environment variables for an OpenShift CI job (config >
  workflow > chain > step). Use when debugging job env, operator channels,
  catalog sources, or override tracking.
---
# Effective Environment Variables

Resolve what env vars a job actually gets after the full step-registry chain.

## Lookup by job name

```bash
python3 .claude/scripts/effective_env_lookup.py <job-name> \
  [--component hypershift] \
  [--version 4.21] \
  [--filter metallb]
```

Examples:

```bash
python3 .claude/scripts/effective_env_lookup.py e2e-aws-minimal --component hypershift --version 4.21
python3 .claude/scripts/effective_env_lookup.py e2e-kubevirt-metal-ovn --component hypershift --version 4.21 --filter metallb
```

Add `--json` for machine-readable output (single JSON document with a `results` array).

Include `openshift-priv` configs with `--include-priv` (excluded by default to avoid duplicate public/priv output).

## Known config file

When the config path is already known:

```bash
python3 .claude/scripts/effective_env.py <config.yaml> <job-name> [--filter <pattern>]
```

## Narrowing results

| Flag | Example | Effect |
|------|---------|--------|
| `--component` | `hypershift` | paths containing `hypershift` |
| `--component` | `openshift/hypershift` | only that config subtree |
| `--version` | `4.21` or `4.21,4.20` | `*release-4.21*` filenames |
| `--filter` | `lvm` | env var names only |
| `--max-configs` | `5` | raise multi-match cap (default: 3) |
| `--include-priv` | | include `openshift-priv/` configs (default: public only) |

If multiple configs match, pass `--version` / `--component`, raise `--max-configs`, or inspect listed paths.

## Reading output

- Priority: **config** > **workflow** > **chain** > **step**
- `⚠️` marks vars overridden from step defaults
- Empty values may be set at runtime in the step script

Do not grep step-registry manually for env resolution — use these scripts.
