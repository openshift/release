# Ginkgo 2.27.2 classifier fixtures

These JSON/JUnit pairs are sanitized output from a real, isolated Ginkgo
2.27.2 suite. The suite has no cluster imports, kubeconfig, network calls, or
OpenShift dependencies. `probe_suite_test.go` is the exact probe source.

Generation used the module-matched `Ginkgo Version 2.27.2` binary (SHA-256
`2e2527ad33a32b6fd8f056a47dd0920be7830aec986d3b8500e9c6e7a5a76c50`) and
the dependency graph at OPP source commit
`45aa96dde952598cae0e601148b139b51ad5fb99`. Each scenario was invoked with:

```text
PROBE_SCENARIO=<scenario> ginkgo --no-color -v --grace-period=300ms \
  --json-report=<scenario>/report.json \
  --junit-report=<scenario>/report.xml .
```

Sanitization replaces checkout-local paths with `/fixture` paths, normalizes
JSON timestamps while retaining JSON structured durations, and normalizes raw
stack-trace indentation. XML structured `time` attributes are normalized to
`0.001`; original timestamp and elapsed strings remain embedded in reporter
text. The XML also retains synthetic `example.test/acm-obs-fixture` stack names
because they are safe reporter output used to preserve the original document
shape.
The fixtures contain no private hostnames, identities, credentials,
kubeconfigs, tokens, or cluster data. Sanitization does not synthesize or
change report states, failure structures, XML elements, or aggregate counters.
In
particular, `skipped-pending` preserves Ginkgo's distinct suite counters
(`skipped=1`, `disabled=1`), and `timeout-nested` preserves the genuine nested
`Failure.AdditionalFailure` emitted after a timed-out node later fails.

The focused harness copies these reports into its private work tree. Its
negative schema cases mutate those copies to model corrupt producer output;
the checked-in oracle remains unchanged.
