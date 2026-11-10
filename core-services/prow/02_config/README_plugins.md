# Plugin Configuration (`_pluginconfig.yaml`)

Plugin configuration fragments are stored in `_pluginconfig.yaml` files at org and
repo levels. They get merged into the final `plugins.yaml`.

## `external_plugins`

### Config structure

`external_plugins` is a `map[string][]ExternalPlugin` where each key is either an
**org** (e.g. `openshift`) or an **org/repo** (e.g. `openshift/api`). There is no
global wildcard key (no `"*"` equivalent).

```yaml
external_plugins:
  # Org-level: applies to all repos in the org
  myorg:
  - name: refresh
    endpoint: http://refresh
    events:
    - issue_comment
  # Repo-level: applies only to this specific repo
  myorg/myrepo:
  - name: needs-rebase
    endpoint: http://needs-rebase
    events:
    - pull_request
```

### Fragment merging (build time)

When fragments are merged, each `external_plugins.<key>` entry must appear in
exactly one fragment. If two fragments define `external_plugins` with the same key
(e.g. both an org-level and a repo-level fragment define
`external_plugins.myorg/myrepo`), the merge fails with a duplicate config error.
There is no override or precedence — it is an error.

For example, an org-level fragment and a repo-level fragment can coexist as long
as they use different keys:

```yaml
# myorg/_pluginconfig.yaml — registers plugins under the org key
external_plugins:
  myorg:
  - name: jira-lifecycle-plugin
    endpoint: http://jira-lifecycle-plugin
    events:
    - issue_comment
    - pull_request
```

```yaml
# myorg/myrepo/_pluginconfig.yaml — registers plugins under the repo key
external_plugins:
  myorg/myrepo:
  - name: refresh
    endpoint: http://refresh
    events:
    - issue_comment
```

But this would be a merge error — same key in two fragments:

```yaml
# ERROR: both fragments define external_plugins.myorg/myrepo
# Fragment A
external_plugins:
  myorg/myrepo:
  - name: refresh
    ...

# Fragment B
external_plugins:
  myorg/myrepo:
  - name: needs-rebase
    ...
```

### Runtime cascading (dispatch time)

When Prow receives a webhook for `org/repo`, it collects external plugins from
**both** matching keys:

1. Plugins registered under the exact `org/repo` key
2. Plugins registered under the `org` key

Both sets are unioned into a flat list and all matching plugins receive the event.
There is no override or filtering — org-level plugins always apply to all repos in
that org.

For the example above, a webhook for `myorg/myrepo` would dispatch to both
`jira-lifecycle-plugin` (from the org key) and `refresh` (from the repo key).
A webhook for `myorg/other-repo` would only dispatch to `jira-lifecycle-plugin`.

### Validation constraint

The same external plugin **name** must not appear in both the org-level and
repo-level key for the same repo. For example, if `refresh` is configured under
`myorg`, it must not also appear under `myorg/myrepo`. Prow rejects such
configurations as duplicates at validation time.

```yaml
# ERROR: "refresh" appears under both myorg and myorg/myrepo
external_plugins:
  myorg:
  - name: refresh
    endpoint: http://refresh
    events:
    - issue_comment
  myorg/myrepo:
  - name: refresh
    endpoint: http://refresh
    events:
    - issue_comment
```

### Practical implication

Because of the no-duplicate rule, the typical pattern in this directory is:

- **Org-level fragments** (`<org>/_pluginconfig.yaml`) register external plugins
  under the org key when they should apply to all repos in that org.
- **Repo-level fragments** (`<org>/<repo>/_pluginconfig.yaml`) register external
  plugins under the `org/repo` key for repo-specific plugins, and must not repeat
  any plugin already configured at the org level.
