# Installer payload build trigger (ART-25170)

The release controller launches this informing job when the payload reaches
`Ready`: its image build has completed and the image is published. This does not
wait for `Accepted`, QE, or shipment approval. The controller supplies the exact
payload as `RELEASE_IMAGE_LATEST`. The job runs `artcd trigger-installer-build`,
which resolves the corresponding installer group and submits the existing
`build-layered-products` Pipeline in `art-installer-agent-tenant`.

Initial nightly coverage is OCP 4.22, matching the current installer group.
The amd64 stable stream also uses this job for named releases; versions without
a matching installer group are skipped. Enable the same job on another nightly
stream when its installer metadata is onboarded. The default `latest` release
in the CI configuration is overridden by the release controller's payload.
Existing groups using the legacy `installer-ove-ui` product, including 4.21,
must migrate to `openshift_agent_installer` before they can submit builds.

## Rollout prerequisites

The hook is deliberately `disabled: true` until both prerequisites are met:

1. Merge/deploy art-tools containing the new command.
2. Provision `art/installer-build-trigger/kubeconfig` in the CI credential
   service. It must authenticate to the ART cluster and allow `get`/`create` of
   PipelineRuns in `art-installer-agent-tenant`. It needs no permission to read
   secrets or start ISO production release jobs. Confirm the service-account
   identity and permission checks with the namespace owner; no credential is
   created by this PR. Sustainable credential lifecycle is ART-25171.

After a dry-run rehearsal and an authorized live test, remove `disabled: true`
from the two public release-controller verification entries and regenerate
the private configuration. Keep `optional: true` so
installer submission does not block OCP payload acceptance.

## Behavior and testing

Nightly and named payloads are supported. Initial installer architecture is
amd64/x86_64, matching its metadata. The trigger uses a digest pullspec and a
deterministic PipelineRun name; repeated submissions reuse the same matching
run while it exists. A failed existing run is not silently rebuilt. Deliberate
rebuilds remain manual; deduplication does not survive removal of its run record.

Set `INSTALLER_TRIGGER_DRY_RUN=true` for rehearsal. Verify the supplied payload,
installer group, digest, target cluster and namespace. Rehearsal cannot enable
the release-controller hook or provision credentials. No live build is needed
for the art-tools unit tests.

This submits a build only. Shipped-payload gating and automatic RPA merge
requests are separate work (ART-25172 and ART-25173).
