# CoreOS ART publication

The existing images postsubmit publishes `stream-coreos` and
`stream-coreos-extensions` to `origin/scos-5.1-art` after successful normal,
reference-only CI promotion to `origin/scos-5.1`.
## Required inputs
- `STREAM_COREOS_IMAGE` and `STREAM_COREOS_EXTENSIONS_IMAGE`: originating manifest-list digest references.
- `/etc/app-ci-kubeconfig/kubeconfig`: ART ImageStream access.
- `/etc/push-secret/.dockerconfigjson`: source pull and destination push credentials.
CI injects the dependency envs and mounts credential files; the CLI image does not supply them.

## Publishing flow
1. Build and normally promote CI images; validate fresh job-specific artifacts.
2. Reuse those digests without rebuilding; verify CI references and mirror manifest lists.
3. Update each ART tag to request `PreserveOriginal` imports; wait for matching digests/generations.

Missing inputs, import errors, timeouts and superseding updates fail the job.
Updates are non-atomic: a second-tag failure leaves the first update in place, without rollback.
Only optimistic conflicts retry; ambiguous update failures are not assumed successful.
Diagnostics omit raw references and client errors that could contain credentials.
Writes use `quay.io/openshift/ci`; imports pull through `quay-proxy.ci.openshift.org`.
Build13 network reachability and live imports require runtime validation.
