# Cross-cluster AWS backup and restore workflow plan

## Goal

Add a separate CI workflow named **hypershift-aws-e2e-backuprestore-cross-cluster**. It will back up a HostedCluster managed by source management cluster A and restore it onto target management cluster B.

The existing **hypershift-aws-e2e-backuprestore** workflow and its original **test-backuprestore** chain remain unchanged. The two workflows may be combined later; this plan keeps them separate.

## Proposed workflow

### Pre phase

1. Create two nested management clusters with stable **source** and **target** roles. Give each a distinct cluster name, saved state, and management kubeconfig.
2. Install HyperShift with external-DNS enabled on both management clusters. Pass the same explicit, workflow-scoped **--external-dns-txt-owner-id** to both installs. Derive its value from the Prow job ID so concurrent jobs use separate owners.
3. Create the source HostedCluster on manager A only. Pass **HYPERSHIFT_EXTERNAL_DNS_DOMAIN** to **hypershift-aws-create** so its services receive the intended hostnames. Manager B starts without a HostedCluster.
4. Run **operatorhub-subscribe-oadp-operator** against each management cluster.
5. Run **hypershift-aws-oadp-setup** against each management cluster. Each gets its own local OADP credential Secret and BSL; both BSLs refer to the same S3 bucket, prefix, and region.

Run steps 4 and 5 in the pre phase, selecting the matching manager kubeconfig for each invocation. Create the shared bucket once, or make bucket creation idempotent. Delete it once after the test is finished.

### Test phase

Add a new step-registry chain for the cross-cluster test. It calls **test-cross-cluster-restore** with:

- **KUBECONFIG_SOURCE** pointing to manager A's kubeconfig.
- **KUBECONFIG_TARGET** pointing to manager B's kubeconfig.

The binary creates its own backup on A and pauses source HostedCluster reconciliation immediately before restoring on B. As part of the handoff, it deletes the ExternalDNS Deployment from manager A and waits for it to stop so only manager B's ExternalDNS instance can reconcile the HostedCluster's DNS names. It then restores the HostedCluster from the backup on B. The restored HostedCluster inherits its identity and configured service hostnames from the backup. Once its Routes are available, ExternalDNS on B updates the DNS records and their targets to the target router. The binary should wait for this reconciliation as part of the restore test; it does not create DNS records directly.

Keep the source ExternalDNS Deployment stopped for the rest of the test. The target ExternalDNS instance uses the shared TXT owner ID to take over the existing records without an ownership conflict. Having only one active reconciler during the handoff prevents the record from flipping between the source and target routers.

### Post phase

1. Collect diagnostics from both management clusters with the matching kubeconfigs.
2. Destroy the restored AWS HostedCluster through manager B first, using **hypershift-aws-destroy-target**. Allow manager B's ExternalDNS to remove the DNS and TXT records after the Routes disappear.
3. Always attempt **hypershift-aws-destroy** against manager A as best-effort cleanup. This removes any remaining source-side HostedCluster state; the shared AWS infrastructure may already have been removed by the target cleanup.
4. Delete the shared S3 bucket once.
5. Destroy the target and source nested management clusters one at a time, using their role-specific names and state. Their destruction removes the manager-local OADP resources.

## Changes needed

### Role-specific cluster state

The nested management setup currently derives the management cluster name from the Prow job ID and writes fixed kubeconfig and metadata paths. Calling it twice would collide. Add a source/target role input or role-specific wrapper chains for setup, install, diagnostics, and destroy. Preserve separate kubeconfigs, manager names, namespaces, and other teardown state.

The workflow creates the AWS HostedCluster only once, on A. The restored HostedCluster on B comes from that backup, so the workflow should not run a second **hypershift-aws-create** there.

### HyperShift install and DNS

The AWS branch of **hypershift-install** currently configures the external-DNS provider, credentials, and domain filter unconditionally. Preserve that behavior and add an input for **--external-dns-txt-owner-id**. Set the same explicit owner ID on both manager installs, scoped to the Prow job, and keep their ExternalDNS domain filters aligned.

Keep **HYPERSHIFT_EXTERNAL_DNS_DOMAIN** on the source **hypershift-aws-create** invocation. This assigns service hostnames. The test binary pauses source HostedCluster reconciliation and deletes the source manager's ExternalDNS Deployment before restoring on the target. The target manager's ExternalDNS then takes over the shared DNS records using the same TXT owner ID and updates their targets to its router. The target instance removes the records when the restored HostedCluster is destroyed.

### OADP and credentials

Create separate OADP resources on each manager, with both BSLs pointing to the same S3 bucket and prefix. Pass the same explicit bucket name and region to both setup invocations. Make bucket creation idempotent or move it to a single shared setup action; make bucket deletion a single post action.

The same AWS credential file can be used for OADP on both managers when it has access to the shared bucket. ExternalDNS on each manager uses its configured AWS credentials for Route 53 reconciliation; the test binary does not need separate DNS writer credentials. No separate AWS credential set is needed solely because there are two management clusters; role-specific names and saved state are needed to prevent collisions.

## CI registration

Add step-registry YAML and metadata for the new workflow and test chain. Register the new workflow as a CI target in the relevant HyperShift job configuration when it is ready to run.

## Repository details behind the plan

- The existing workflow calls **hypershift-e2e-backuprestore**, which runs **test-backuprestore** and conformance: [workflow](../../ci-operator/step-registry/hypershift/aws/e2e-backuprestore/hypershift-aws-e2e-backuprestore-workflow.yaml), [chain](../../ci-operator/step-registry/hypershift/e2e-backuprestore/hypershift-e2e-backuprestore-chain.yaml).
- The nested management setup derives its name from the Prow job ID and writes fixed kubeconfig paths: [setup chain](../../ci-operator/step-registry/hypershift/setup-nested-management-cluster/hypershift-setup-nested-management-cluster-chain.yaml).
- The AWS install script currently adds external-DNS flags in its AWS branch: [install script](../../ci-operator/step-registry/hypershift/install/hypershift-install-commands.sh).
- The OADP setup creates an S3 bucket on each invocation: [OADP setup](../../ci-operator/step-registry/hypershift/aws/oadp-setup/hypershift-aws-oadp-setup-commands.sh).

The CI workflow and chain configuration enable ExternalDNS on both management
clusters, pass the same Prow-job-scoped TXT owner ID, and leave DNS
reconciliation to the target ExternalDNS instance after source handoff. The
`test-cross-cluster-restore` binary is maintained outside this repository and
must provide the documented kubeconfig, source ExternalDNS deletion, and DNS
handoff behavior before the workflow can run successfully.

