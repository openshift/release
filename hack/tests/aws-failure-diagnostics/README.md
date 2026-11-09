# AWS failure diagnostics tests

Tests for the opt-in AWS failure context capture used by the ROSA HCP
conformance job.

Run them with:

```bash
make test-aws-failure-diagnostics
```

Requirements: `bash`, `python3` and `jq`. No cloud credentials are used and no
AWS API call is made: the AWS CLI is replaced by a stub on `PATH`, and `oc` is
replaced by a stub that serves fixture node and infrastructure output.

## What is under test

| Component | Location |
|---|---|
| capture helper and its extractor program | inline `commands` of `ci-operator/step-registry/hypershift/conformance/hypershift-conformance-chain.yaml`, between the `aws-failure-diagnostics` markers |
| post-phase account-match step | `ci-operator/step-registry/rosa/aws/hcp/diagnose-aws-identity/` |
| wiring | `ci-operator/step-registry/rosa/aws/hcp/conformance/rosa-aws-hcp-conformance-workflow.yaml` and `ci-operator/config/openshift/release/openshift-release-main__nightly-5.0.yaml` |

The capture helper has to live inside the conformance step, because
`${ARTIFACT_DIR}` is per step pod and no later post step can read the suite's
JUnit output. `extract.py` pulls the shipped text out of the chain so the tests
exercise exactly what runs in CI rather than a copy that could drift.

## Covered behaviour

* request ID, error code, HTTP status, service, operation, instance ID and
  per-test timestamps extracted from JUnit `<failure>` text, including XML
  entity escapes;
* node names, providerIDs, instance IDs, zones and regions;
* configured versus observed region evidence, each with its provenance, and an
  explicit "unknown" for the region the test process actually resolved;
* credential-chain provability, and the resulting `unknown` account-match
  status even when the two account values are identical;
* account match, mismatch, missing reference, malformed reference and failed
  STS read;
* rejection of credential-shaped values in every position the suite under test
  controls: a key-like or secret-key-shaped error code, a JWT, a secret-shaped
  request ID, a bare account ID offered as a request ID, and prose offered as
  an AWS service name;
* decoding of XML entity escapes, asserted with a numeric escape that cannot be
  matched around;
* refusal of a JUnit file that declares a DTD anywhere in the file, and of an
  oversized one, so the XML parser cannot be driven into unbounded expansion;
* suite results being scanned first when the file-count bound applies, and the
  bound being recorded rather than applied silently;
* the extractor itself failing, a missing credential file and a missing AWS
  CLI;
* bounded output, malformed and missing inputs, the gate-disabled path, the
  passing-suite path and preservation of the original suite exit status;
* sentinel secrets, account IDs and ARNs placed in the fixtures must not appear
  in any artifact, stdout or stderr.
