# Lease health authentication

The initial login and logins when switching OCM environments share the same
policy: at most three attempts, with 10 and 20 seconds between retries.
Only the JSON-versus-HTML content-type mismatch and selected transport errors
(I/O or TLS handshake timeout, connection reset, unexpected EOF, temporary name
resolution failure, or context deadline exceeded) are retried. These signatures
are retry candidates, not proof that the upstream problem is transient or has
recovered. Explicit authentication rejections take precedence over retry
signatures; unknown errors fail immediately. Exhaustion preserves the final
nonzero CLI exit code and stops the health check. The remembered environment
changes only after login succeeds.

Before authentication, the step creates `lease-health-report.txt` and
`lease-health-auth.jsonl` in `ARTIFACT_DIR`. Each attempt records a start event
and a result event in both artifacts and stderr. Events contain UTC time,
operation, an allowlisted environment label (otherwise `other`), attempt and
maximum attempts, CLI exit code (`null` for start), and a fixed classification.

Login stdout and stderr are captured only for classification and never copied
to logs or artifacts, including on success. Tracing is disabled before handling
credentials. No request/response bodies, tokens, client secrets, authorization
headers, or credential-file contents are emitted. HTTP status and endpoint are
reported as `unknown`: ordinary CLI errors do not reliably provide those fields,
and verbose HTTP diagnostics could disclose credentials. The artifacts cannot
establish the exact upstream cause or HTTP response status.

Run the offline regression suite from the repository root:

```sh
bash hack/test-rosa-cluster-lease-health-auth.sh
```

The suite requires Bash, jq, and standard shell utilities; OCM calls and sleeps
are mocked, and credentials are synthetic temporary fixtures. It does not query
clouds or trigger CI.

Inline-entry tests also run the complete command script through `bash -c`, as
ci-operator does. They substitute only the fixed lease-host kubeconfig path with
a synthetic fixture path and export mocks for OCM, oc, and sleep. This covers
startup ordering and authentication failure without accessing real credentials
or changing lease or cluster state.
