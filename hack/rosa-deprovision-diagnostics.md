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
availability, state and two deletion controls. State accepts only `error` or
`uninstalling`; configuration mode accepts only `full` or `read_only`. All other
enum values are withheld. Delete protection accepts only an actual JSON boolean;
missing or malformed values become null, never an inferred false. No free-form
fields, identifiers or account data are kept.
Oversized responses are truncated before parsing. Malformed or failed responses
yield an unavailable state; a truncated response is usable only if it still
parses as exactly one JSON object.
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

## Public schema basis and diagnostic limits

ROSA describe's JSON format marshals the OCM cluster, including optional status
and delete protection. Public source pinned to ROSA commit
`0b585b2d1d244d23287a2110ad393bc279430d4f` proves the consumer and wire fields:

- [JSON formatter](https://github.com/openshift/rosa/blob/0b585b2d1d244d23287a2110ad393bc279430d4f/cmd/describe/cluster/cmd.go#L904).
- [Configuration mode enum](https://github.com/openshift/rosa/blob/0b585b2d1d244d23287a2110ad393bc279430d4f/vendor/github.com/openshift-online/ocm-api-model/clientapi/clustersmgmt/v1/cluster_configuration_mode_type.go#L26):
  `read_only` explicitly disallows cluster deletion, unlike `full`.
- [Cluster status schema](https://github.com/openshift/rosa/blob/0b585b2d1d244d23287a2110ad393bc279430d4f/vendor/github.com/openshift-online/ocm-api-model/model/clusters_mgmt/v1/cluster_status_type.model#L17)
  exposes configuration mode; provisioning error codes/messages are strings,
  not proven deletion-specific enums, so they are excluded.
- [Delete protection boolean](https://github.com/openshift/rosa/blob/0b585b2d1d244d23287a2110ad393bc279430d4f/vendor/github.com/openshift-online/ocm-api-model/clientapi/clustersmgmt/v1/delete_protection_type.go#L43)
  and [its purpose in the CLI](https://github.com/openshift/rosa/blob/0b585b2d1d244d23287a2110ad393bc279430d4f/cmd/create/cluster/cmd.go#L814):
  protection against accidental deletion.

With the same generic error state, `read_only` identifies a current configuration
restriction; enabled delete protection identifies a deletion guard. `full` and
false mean only that neither control is reported as restrictive at collection
time; they do not rule out an earlier restriction. These observations help check
current deletion controls alongside other teardown failures, without proving
that either control caused an already-accepted deletion to stall. They are a
later snapshot, not a history. Absence is unknown, not unrestricted.
This does not capture complete root cause or distinguish infrastructure cleanup
failures such as resource dependencies versus permissions. DNS/OIDC readiness,
compute replicas and limited-support counts are omitted because their schemas do
not establish a deletion failure classification. Existing management-cluster
gather consumers require additional cluster access, outside this step's scope.

The registry validator also supports offline checking via `KUBECONFIG`. Use an
anonymous fixture with a loopback dummy server, read-only source/fixture mounts,
and `podman run --pull never --network none` with the existing configresolver
image, `--config ./ci-operator/config/ --registry ./ci-operator/step-registry/
--validate-only`. This supplies no credentials and exits before client use.
