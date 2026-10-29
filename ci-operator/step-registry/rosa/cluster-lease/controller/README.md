# Controller authentication

The controller initializes `controller-report.txt` and `controller-auth.jsonl`
before checking the lease kubeconfig or logging into OCM. Initial login and
environment switches each use a maximum of three total attempts per login, with
exactly 10 seconds between failed attempts. There is no sleep after success or
the final failure. Complete SSO client credentials take precedence
over the offline token; an incomplete client pair still falls back to the token.
A rejected client login does not fall back to a different credential.

Every failed OCM login is retried, including unrecognized errors and credential
rejections. Missing credential inputs fail validation immediately without an OCM
login attempt or sleep. Failure classifications are diagnostic only and never
control retries. The final OCM CLI exit code is preserved, and the remembered environment changes only
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
Cases verify first-attempt success, second- and third-attempt recovery, all
failure classes retrying, fixed sleep counts, final CLI exit codes, environment
switches, immediate missing-credential validation, and credential-safe output.

This change is controller-only and independent of the health step in PR 87502.
No registry definitions or generated metadata inputs change, so regeneration is
not needed.
