# Account-role authentication

Both account-role create and delete initialize an operation-specific
`account-roles-{create,delete}-auth.jsonl` in `ARTIFACT_DIR` before setup and login.
Each login attempt writes UTC time, operation, allowlisted environment (otherwise
`other`), attempt/max attempts, exit code (`null` at start), and classification to
the artifact and stderr. Missing credentials produce an attempt-zero event.
Endpoint and HTTP status remain `unknown`; the CLI output does not reliably
establish them without potentially unsafe diagnostics.

Authentication uses SSO credentials when both are present, otherwise the existing
offline token fallback. Login gets at most three attempts with 10/20 second
backoff, only for the observed JSON/HTML content-type mismatch or selected
transport signatures: I/O timeout, TLS handshake timeout, connection reset by
peer, unexpected EOF, temporary name resolution failure, and context deadline
exceeded. Explicit authentication rejection takes precedence, and unknown errors
fail immediately. The final nonzero CLI status is preserved and role operations
do not run on authentication failure. Existing IAM operation behavior is unchanged.

These signatures are retry candidates, not evidence of an underlying outage,
transience, or resolution of an upstream problem. Raw login stdout/stderr are
captured only for classification and never emitted, even on success. Tracing is
disabled before credentials are read; no credential values, headers, or response
bodies are included in authentication diagnostics.

The authentication functions are intentionally embedded in both command scripts:
ci-operator executes registry commands inline with `bash -c`, without a
checkout-local helper. Offline tests check that the implementations stay equal.
No registry definitions or generated ownership/path metadata change.

Run from the repository root:

```sh
bash hack/test-rosa-sts-account-roles-auth.sh
```

The suite requires Bash, Python 3, jq, and standard shell utilities. It runs both
complete scripts inline, with synthetic credential files and mocked ROSA/AWS
commands and sleeps. It makes no authentication, cloud, cluster, or network calls.
