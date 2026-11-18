# Devcontainer dependency report

This read-only checker inventories dependency declarations in the public
`.devcontainer` definitions of `openshift/sippy`, `openshift/origin`, and
`openshift-eng/ship-status-dash`. The weekly Prow periodic publishes Markdown
and JSON under its step artifacts. It does not build those repositories, change
dependencies, open pull requests, use credentials, or send external reports.

Pinned entries use a named public version source and an explicit inclusive /
exclusive policy range. Only stable three-part versions are candidates, and a
downgrade is never proposed. A candidate is not a compatibility claim. Floating,
repository-coupled, manual, and unsupported declarations are reported without a
proposal; repository-coupled entries name the authority that must approve a
change. Missing files, lookup failures, and zero or multiple extraction matches
are explicit errors and are never described as up to date.

Run the same checker on demand from the `openshift/release` root:

```sh
python3 ci-operator/step-registry/openshift/devcontainer-dependency-report/openshift-devcontainer-dependency-report-commands.py \
  --output-dir /tmp/devcontainer-dependency-report
```

Run the recorded-response unit tests without network access:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 \
  hack/test_devcontainer_dependency_report.py
```

The checker uses only the Python standard library. Inventory and extraction
policy live in `openshift-devcontainer-dependency-report-config.md` (raw JSON with
a registry-compatible documentation extension); add a new repository
or declaration there rather than adding repository-specific code.
