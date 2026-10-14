# CoreOS ART publication

The `publish-art` postsubmit publishes `stream-coreos` and
`stream-coreos-extensions` to `origin/scos-5.1-art`. Separate, reference-only CI
promotion to `origin/scos-5.1` remains unchanged.

## Required inputs
- `STREAM_COREOS_IMAGE` and `STREAM_COREOS_EXTENSIONS_IMAGE`: immutable digest pull specs.
- `/etc/app-ci-kubeconfig/kubeconfig`: ART ImageStream access.
- `/etc/push-secret/.dockerconfigjson`: source pull and destination push credentials.
CI injects the dependency envs and mounts credential files; the CLI image does not supply them.

## Publishing flow
1. Mirror both build digests, preserving manifest lists.
2. Atomically update both ART tag specs to request `PreserveOriginal` imports.
3. Wait for nonempty imported images matching the expected digests and current generations.

Missing inputs, import errors, timeouts and superseding updates fail the job.
Only optimistic conflicts retry; ambiguous update failures are not assumed successful.
Diagnostics omit raw references and client errors that could contain credentials.
Writes use `quay.io/openshift/ci`; imports pull through `quay-proxy.ci.openshift.org`.
Build13 network reachability and live imports require runtime validation.
