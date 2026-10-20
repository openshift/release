# Offline deprovision diagnostics checks

Run `python3 hack/test_rosa_deprovision.py` and
`shellcheck -S warning ci-operator/step-registry/rosa/cluster/deprovision/rosa-cluster-deprovision-commands.sh`.
All ROSA commands, credentials, identifiers, timestamps and sleeps in the test
are local fixtures. The timeout wrapper checks production arguments and uses a
shorter real GNU timeout to exercise termination without contacting services.

On the existing timeout and error exits only, one additional describe command
gets 15 seconds plus a 2-second kill grace. Only its first 32768 bytes enter
memory; raw output and stderr are never written to artifacts or logged.
The JSON artifact and summary allow only a fixed failure reason, collection
availability and state. State accepts only `error` or `uninstalling`; all other
values are withheld. No free-form fields, identifiers or account data are kept.
Malformed, oversized/truncated or failed responses yield an unavailable state.
Artifact write failure is best effort and the original exit remains 1.

The command and `.state` field already exist in this step. The registry's
`rosa/cluster/wait-ready/cluster` step also uses bounded `rosa describe cluster
-c ... -o json`. Uninstall logs are deliberately not collected: free-form log
content has no demonstrated complete sanitization contract in these consumers.
Regex replacement cannot reliably remove arbitrary credentials or account data.
No diagnostic cloud/resource operations, force deletion, extra delete retries,
timeout changes or role-cleanup changes are introduced.

The step-registry shell consumer runs `hack/validate-registry-commands.sh`
(shellcheck at warning severity). The metadata consumer runs
`hack/validate-registry-metadata.sh`; metadata records paths and owners, neither
of which changes here. No registry YAML or CI configuration changes, so no
generated artifact updates are required. Full registry validation and publishing
remain separate phases.
