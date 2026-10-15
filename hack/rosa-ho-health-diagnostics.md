# HO health diagnostics regression checks

Run `bash hack/validate-rosa-ho-health-diagnostics.sh` locally. The harness
executes both registry command scripts with mocked `oc`, `ocm`, `curl`, and
`sleep`; it needs Bash, jq and standard GNU utilities (including `sha256sum`)
and makes no cluster or network requests.
Run `shellcheck -S warning` and `bash -n` on the changed shell scripts as well,
following `hack/validate-registry-commands.sh`.

The `rosa-e2e-hcp-ho-upgrade` workflow runs deploy followed by health verification.
The refs consume these command scripts directly; shell-only changes do not
change registry metadata or generated Prow configuration. No generator is needed.
The deploy ref is also consumed directly by the hypershift-ci configuration.

Each step retains allowlisted health metadata under `${ARTIFACT_DIR}/ho-health`:

- `before-deploy-{hostedclusters,nodepools}.json`: after obtaining the management
  kubeconfig, before any attempted image mutation, image-match exit or lock exit.
- `after-deploy-{hostedclusters,nodepools}.json`: on deploy exit after baseline
  collection, including skipped deployments and failed image changes or rollouts.
  This is not proof of upgrade.
- `after-verification-{hostedclusters,nodepools}.json`: on verification exit,
  including failed checks and early command failures.

Snapshots include UTC collection timestamps, resource identity and generation,
and full condition type/status/reason/message/transition time/observed generation.
Specifications, credential fields, Secrets, annotations, and pod environments are
excluded. Condition messages are retained verbatim and remain free-form text.
Collection errors are explicit warnings in the step log. Collection is skipped
with a warning if the management kubeconfig is missing, rather than falling back
to a different cluster context. Diagnostic API requests
have a 15-second request timeout; collection is best effort and does not change
the step result.
All-namespace checks, readiness criteria, grace periods and timeouts are unchanged.
These artifacts enable comparison; they neither fix a readiness failure nor
establish whether it predates an upgrade.
