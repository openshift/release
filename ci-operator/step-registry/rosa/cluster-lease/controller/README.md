# Controller authentication

The controller initializes `controller-report.txt` and `controller-auth.jsonl`
before checking the lease kubeconfig or logging into OCM. Initial login and
environment switches share a maximum of three attempts per login, with 10 and
20 seconds between attempts. Complete SSO client credentials take precedence
over the offline token; an incomplete client pair still falls back to the token.
A rejected client login does not fall back to a different credential.

Only the observed `expected response content type 'application/json' but received
'text/html'` mismatch and these explicitly selected transport signatures retry
(case insensitive): `i/o timeout`, `TLS handshake timeout`, `connection reset by
peer`, `unexpected EOF`, `temporary failure in name resolution`, and `context
deadline exceeded`. Permanent authentication rejection takes precedence even
when a retry signature is also present. Other errors fail immediately. The final
OCM CLI exit code is preserved, and the remembered environment changes only
after successful login. Failed login stops reconciliation before using the
wrong environment; retry exhaustion does not resolve the upstream dependency.

Diagnostics record start/result, time, operation, allowlisted environment,
attempt, maximum attempts, exit code, and failure class. Environment values
other than `production`, `prod`, `staging`, `stage`, or `integration` become
`other`. Endpoint and HTTP status are explicitly `unknown`: CLI text and an
HTML response do not establish which endpoint failed, an HTTP status, an outage,
transience, or the underlying cause. Captured CLI output is classified in memory
and never emitted, even on success. Shell tracing is disabled before credential
loading. Do not add raw output, bodies, headers, tokens, or credential tracing
to these publicly retained artifacts.

## Offline regression checks

From the repository root (Bash and jq required):

```sh
bash hack/test-rosa-cluster-lease-controller-auth.sh
bash -n ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh hack/test-rosa-cluster-lease-controller-auth.sh
shellcheck -S warning ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh hack/test-rosa-cluster-lease-controller-auth.sh
```

The suite uses only fake credentials and mocked commands. Sourcing loads auth
helpers without kubeconfig checks or reconciliation. Inline cases execute the
complete script using `bash -c`, as ci-operator's
`pkg/steps/multi_stage/gen.go` does (command prefix `#!/bin/bash` and `set -eu`).
The fixture substitutes only the hardcoded lease kubeconfig path with a temporary
empty file, and mocks desired-state reads while using the embedded Python YAML
parser unchanged. It requires no
live OCM, cloud, or Kubernetes access and performs no CI triggers or mutations.

This change is controller-only and independent of the health step in PR 87502.
No registry definitions or generated metadata inputs change, so regeneration is
not needed.
