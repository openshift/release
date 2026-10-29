# STS account-role login

Only the login in this step is hardened. A complete SSO client pair still takes
precedence over the offline token; an incomplete pair can use the token as before.
A rejected login never selects alternate credentials. Role creation, version
fallback, cleanup, and other provisioning paths are unchanged.

Login has at most three attempts, with 10 and 20 second delays. The retry candidates
are the exact SDK message `expected response content type 'application/json' but
received 'text/html'`, or `TLS handshake timeout`, `i/o timeout`, and
`connection reset by peer` (case insensitive). Authentication rejection markers
(`invalid_client`, `invalid_grant`, `unauthorized`, `forbidden`, `invalid token`,
`token expired`, `expired token`) take priority. Other errors stop immediately.
Candidates are not evidence of transience, outage, or upstream cause. Failure
preserves the final CLI exit code and stops before `whoami` or role mutation.

`$ARTIFACT_DIR/rosa-sts-account-roles-login.jsonl` contains start/result events,
UTC timestamps, an allowlisted environment (otherwise `unknown`), attempt/max,
CLI exit code, and a fixed classification. Missing credentials use attempt zero
and a null CLI exit code. Endpoint and HTTP status are explicitly `unknown`;
neither can be established from these diagnostics. Tracing is disabled before
credentials are read. Combined login stdout/stderr is held only in memory for
classification and discarded, including on success; raw bodies, credentials,
URLs, and headers are never copied into diagnostics or logs.

Run the standalone offline regressions from the repository root:

```sh
python3 hack/test-rosa-sts-account-roles-login.py
bash -n ci-operator/step-registry/rosa/sts/account-roles/create/rosa-sts-account-roles-create-commands.sh
shellcheck -S warning ci-operator/step-registry/rosa/sts/account-roles/create/rosa-sts-account-roles-create-commands.sh
```

Tests use synthetic credentials and mocked `rosa`, `sleep`, and `aws`, without
network/cloud/API operations. They execute the complete command string through
`/bin/bash -c` with ci-operator's `#!/bin/bash\nset -eu\n` prefix, not by sourcing
another step. Successful login reaches a mocked `whoami` that deliberately exits
89 before any cloud work. Failed login must never reach it. Coverage includes
credential selection, recovery/exhaustion, transport candidates, permanent/unknown
errors, final exit codes, tracing, response-body suppression, and diagnostics.

The step ref still selects the same `-commands.sh` file with inline execution.
No ref, workflow, CI configuration, owners, or metadata inputs change; therefore
job/config/registry-metadata generation is not required for this script-only
behavior change and standalone test/documentation additions.
