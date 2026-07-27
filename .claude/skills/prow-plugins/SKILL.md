---
name: prow-plugins
description: >-
  Determine which Prow plugins are enabled for a given openshift/release
  org or org/repo, and which config level (global/org/repo) enabled each
  one. Use when asked whether a plugin is on/off for a repo, why a bot
  command isn't working, or before adding/removing a plugin.
---
# Prow Plugin Lookup

Resolve the effective set of enabled Prow plugins for an org or org/repo by
running the deterministic resolver script — do not read
`core-services/prow/02_config/**/_pluginconfig.yaml` or `_plugins.yaml`
directly; the script already merges the fragment hierarchy correctly,
including the `excluded_repos` special case.

## Run the resolver

From repo root:

```bash
python3 .claude/scripts/effective_plugins.py openshift/<repo>
python3 .claude/scripts/effective_plugins.py openshift          # org-wide summary
```

Output is JSON. Read only this JSON — it is the source of truth for this task.

## Interpreting the output

For an `org/repo` target:

- `excluded_from_org_defaults` — true if the org's `plugins.<org>.excluded_repos`
  lists this repo. When true, the org's default plugin list does **not** apply
  at all; the repo-level fragment must define its full plugin set on its own.
- `enabled_plugins` — map of plugin name → `{source_level, source_file, note,
  has_global_behavior_settings}`.
  - `source_level: "org"` — plugin comes from the org's default list; every
    non-excluded repo in the org gets it.
  - `source_level: "repo"` — plugin was added specifically for this repo (on
    top of org defaults), or — if `excluded_from_org_defaults` is true — is
    part of the repo's self-contained list.
  - `has_global_behavior_settings` — the plugin has a config block in the
    global `_plugins.yaml` (tuning its behavior). This is *not* what enables
    the plugin — enablement always comes from `enabled_plugins`/
    `enabled_external_plugins` at org or repo level — it just tells you where
    to look for that plugin's settings (e.g. `bugzilla`, `blunderbuss`,
    `label.restricted_labels`).
- `enabled_external_plugins` — same idea for `external_plugins` entries
  (webhook-based plugins with `endpoint`/`events`). These always cascade as a
  **union** of org-key and repo-key entries — there is no `excluded_repos`
  concept for external plugins.
- `warnings` — flags things worth double-checking, e.g. no repo-level
  fragment found, a plugin listed redundantly at both levels, or an external
  plugin name duplicated across org and repo (Prow rejects that at validation
  time).

For an org-only target (no repo), the output is `org_summary`: the org's
`excluded_repos`, `default_plugins`, and `default_external_plugins`.

## A plugin is "disabled" for a repo when

- It does not appear in `enabled_plugins` / `enabled_external_plugins` at all, **and**
- If the repo is excluded from org defaults, it's also absent from the repo's own list.

There is no separate "disable" mechanism beyond simply not listing the plugin
(or, at the org level, adding the repo to `excluded_repos` to opt it out of
the org-wide list entirely).

## Making changes

To enable/disable a plugin for one repo, edit
`core-services/prow/02_config/<org>/<repo>/_pluginconfig.yaml` (create it if
missing) and add/remove the name under `plugins.<org>/<repo>.plugins`. To
change org-wide defaults, edit `plugins.<org>.plugins` in
`<org>/_pluginconfig.yaml` — remember this affects every non-excluded repo.
After editing, re-run the resolver script to confirm the intended effective
result, then run `make check` / `make checkconfig` as usual.
