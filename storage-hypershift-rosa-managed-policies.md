# Plan: gate EBS CSI changes on a ROSA policy HyperShift CSI run

## Gap exposed by TRT-2576

[TRT-2576](https://redhat.atlassian.net/browse/TRT-2576) reverted the [AWS EBS CSI driver rebase](https://github.com/openshift/aws-ebs-csi-driver/pull/301) after a HyperShift payload job found the controller crashlooping. The [required driver HyperShift job](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_aws-ebs-csi-driver/331/pull-ci-openshift-aws-ebs-csi-driver-master-e2e-hypershift/2101075902417866752) already creates a guest with `ROSAAmazonEBSCSIDriverOperatorPolicy`, but runs only `TestCreateCluster`. The existing `e2e-aws-csi` job runs `openshift/csi` on standalone IPI with different IAM. Neither exercises the driver through the CSI suite on a ROSA policy HyperShift guest.

## Change

1. Add a required `e2e-aws-csi-hypershift` presubmit to `aws-ebs-csi-driver`. Use `hypershift-aws-conformance`, whose create and conformance steps share a guest cluster. Set `EXTRA_ARGS: "--use-rosa-managed-policies --shared-role"`, `PUBLIC_ONLY: "true"`, `TEST_SUITE: openshift/csi`, `TEST_CSI_DRIVER_MANIFEST: manifest-aws-ebs.yaml`, and `TEST_OCP_CSI_DRIVER_MANIFEST: ocp-manifest-aws-ebs.yaml`. Add the `hypershift-operator: hypershift/latest` base image needed by the create step. Keep `releases.latest.integration.include_built_images: true` and verify that the guest actually uses the PR-built EBS driver image.
2. Run `storage-conf-csi-aws-ebs` before `hypershift-conformance` to supply the CSI manifests. Check workflow expansion before choosing where to insert it: an overriding `pre:` must retain the workflow's management-cluster setup and `hypershift-aws-create`. Ensure its `aws-ebs-csi-driver-operator-test` input image resolves in each config; the driver repo does not build that image itself. The test must fail if the manifest is missing or the selected `openshift/csi` test list is empty.
3. Make this presubmit a merge gate for driver changes: `always_run: false`, no `optional: true`, and no path filter on the driver repo. Check the generated Prow job and merge policy to confirm that `/lgtm` schedules it and a failed or missing result blocks merge. Keep `e2e-aws-csi` for IPI and the existing `e2e-hypershift` smoke job.
4. Roll out to driver promotion branches, starting with `master` and `release-4.22`, then active `release-4.23` and `release-5.x` branches. Add the same gate to `csi-operator` branches that ship EBS driver changes, using an EBS specific change filter; include `aws-ebs-csi-driver-operator` only where it remains the promotion source. Mirror `openshift-priv` configs where required by current branching. Run `make update` and commit generated `ci-operator/jobs/` files.

## Acceptance checks

- The create log shows `Attached managed policy to shared role` for `ROSAAmazonEBSCSIDriverOperatorPolicy` and a `*-worker-ROSA-Worker-Role`; fail the job if the EBS managed policy is absent. Do not reject the separate, expected inline ingress policy.
- JUnit results show nonempty `openshift/csi` execution on the guest, including volume provisioning and attach; confirm the tested driver image matches the PR build. A passing `TestCreateCluster` alone does not satisfy this check.
- Rehearse against the pre-revert #301 build or another known failing driver build. Confirm the new job fails for the same controller or CSI regression before treating the gate as protection against a repeat of TRT-2576.

Keep HyperShift's `UseROSAManagedPolicies` default, the nested management-cluster IAM, and the AWS-managed policy document outside this CI change. If a required driver action is denied, fix or escalate that policy gap separately.
