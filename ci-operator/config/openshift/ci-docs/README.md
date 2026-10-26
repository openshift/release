# ci-docs link checks

The `links` test runs the inline Ruby command in
`openshift-ci-docs-main.yaml` against the generated ci-docs site using
HTMLProofer 3.19.0. Keep runtime changes in that command: scripts from the
release repository are not available in the ci-docs test image.

Run its deterministic regression suite from the release repository root:

```sh
make test-ci-docs-links
```

The target requires Podman (or `CONTAINER_ENGINE=docker`) and pulls the pinned
`klakegg/html-proofer:3.19.0` image if needed. Tests run with external networking
disabled and serve real HTTP responses over loopback. They exercise the inline
Ruby and the unmodified shell command, including successful retries, exhaustion,
HEAD-to-GET fallback, HTTP 404s, broken local links, and existing status ignores.
Timeout fixtures shorten only their test runner's timeout; the shell-command
integration retains production settings.

Timeouts and HTTP 500/502/503/504 responses get at most two additional attempts
per URL, shared across HEAD and GET, with one- and two-second backoff. Existing
concurrency, checks and ignores remain unchanged. Each attempt has a 10-second
connect timeout and a 30-second overall timeout. Including the existing GET
fallback, there are at most four attempts per URL, not whole-site retries.
Exhausted timeouts must use HTMLProofer's timeout failure handler explicitly:
version 3.19.0 otherwise accepts a 2xx status before checking whether the body
transfer timed out.

After editing the configuration, run `make update` and the repository's
applicable configuration checks; never edit generated job files manually.
