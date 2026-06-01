# Prow Configuration Fragments

This directory contains a hierarchy of Prow configuration fragments that get
merged into final Prow configuration files. The directory structure mirrors
GitHub's org/repo hierarchy:

```
02_config/
  _plugins.yaml              # global plugin config
  _config.yaml               # global prow config
  <org>/
    _pluginconfig.yaml        # org-level plugin config fragment
    _prowconfig.yaml          # org-level prow config fragment
    <repo>/
      _pluginconfig.yaml      # repo-level plugin config fragment
      _prowconfig.yaml        # repo-level prow config fragment
```

Each fragment is merged into the final configuration. The merging rules differ per
configuration section — see the detailed documents below.

## Plugin configuration (`_pluginconfig.yaml`)

- [Plugin configuration](README_plugins.md) — `external_plugins`, ...
