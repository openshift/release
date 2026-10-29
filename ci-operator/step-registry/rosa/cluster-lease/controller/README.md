# Controller authentication

Initial login and environment switches each use a maximum of three total
attempts per login, with exactly 10 seconds between failed attempts. There is no
sleep after success or the final failure. Complete SSO client credentials take
precedence over the offline token; an incomplete client pair still falls back to the token.
A rejected client login does not fall back to a different credential.

Every failed OCM login is retried, including unrecognized errors and credential
rejections. Missing credential inputs fail validation immediately without an OCM
login attempt or sleep. The final OCM CLI exit code is preserved, and the
remembered environment changes only after successful login. Failed login stops
reconciliation before using the wrong environment; retry exhaustion does not
resolve the upstream dependency.

Login stdout and stderr are discarded, even on success. Shell tracing is
disabled before credential loading. Authentication creates no artifacts; the
existing `controller-report.txt` is initialized only after initial authentication
succeeds, at its original reconciliation entry point.

## Offline regression checks

From the repository root (Bash and jq required):

```sh
bash hack/test-rosa-cluster-lease-controller-auth.sh
bash -n ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh
bash -n hack/test-rosa-cluster-lease-controller-auth.sh
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
login failures retrying, fixed sleep counts, final CLI exit codes, environment
switches, immediate missing-credential validation, credential-safe output, no
artifacts before authentication, and the existing report after successful login.

This change is controller-only and independent of the health step in PR 87502.
No registry definitions or generated metadata inputs change, so regeneration is
not needed.
