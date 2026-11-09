# HyperShift pipeline path selection

In `openshift-hypershift-main.yaml`, `e2e-aks-5-0` and `e2e-aws-5-0` use
the same positive `pipeline_run_if_changed` filter:

```text
^(test/e2e|hypershift-operator)/(.{1,2}|.*([^d]|[^m]d|[^.]md))$
```

Either suite is selected when **any** changed file inside `test/e2e/` or
`hypershift-operator/` does not end in lowercase `.md`. Adding Markdown files
to a matching code change does not prevent selection. Changes outside these
directories do not select these suites, even when mixed with documentation.
The slash after the directory alternatives excludes similarly named directories
such as `test/e2e-other/` and `hypershift-operator-other/`.

The suffix expression is an RE2-compatible complement of a final `.md`:

- `.{1,2}` accepts one- or two-character relative paths, too short to end in `.md`.
- `[^d]` accepts an ending other than `d`.
- `[^m]d` accepts a final `d` preceded by something other than `m`.
- `[^.]md` accepts a final `md` preceded by something other than `.`.

The anchors require the directory prefix and suffix to match the whole path.
Matching is case-sensitive: `.MD`, `.Md` and `.mD` are not excluded. These rules
describe ordinary repository-relative changed-file paths without newline characters.

| Changed files | Selected? |
| --- | --- |
| `test/e2e/example.go`, `test/e2e/run.sh` or `hypershift-operator/config.yaml` | Yes |
| `test/e2e/a` or `hypershift-operator/md` | Yes |
| `test/e2e/README.MD`, `test/e2e/.md.go` or `hypershift-operator/foo.md.bak` | Yes |
| `test/e2e/example.go` together with `test/e2e/AGENTS.md` | Yes |
| Only `test/e2e/v2/AGENTS.md` and `hypershift-operator/README.md` | No |
| Only `cmd/main.go`, `support/config/config.go` and `docs/guide.md` | No |
| Only `test/e2e-other/example.go` or `hypershift-operator-other/example.go` | No |

This table documents expected behavior; it is not an executable regression test.
The generated Prow jobs carry the same filter in their annotations. Edit the
source configuration and run `make jobs` from the release repository root rather
than editing generated annotations. This explanation lives outside the YAML
because canonical source normalization removes YAML comments.
