# CNV storage checkup

The initial integration targets CNV builds from `main`. The calling ci-operator
configuration selects the OCP payload, CNV catalog image/channel, worker sizing,
cloud profile, and schedule. These registry components do not pin a product
version. Release configurations can reuse them when coverage is cascaded later.
The initial job follows the existing `cnv-dev-preview-konflux` development lane:
`CNV_VERSION=4.99` and `CNV_OPERATOR_CHANNEL=dev-preview`. With
`CNV_CATALOG_SOURCE=cnv-iib-catalog`, the installer resolves the current catalog
from [CNV CI's version mapping](https://github.com/openshift-cnv/cnv-ci/blob/master/version-mapping.json)
on every run. The mapping is updated independently of this configuration. An
explicit `CNV_CATALOG_IMAGE` overrides it for a reproducible rehearsal.
The selected mapping must contain a non-empty image pullspec. A missing, null,
or malformed entry fails catalog resolution before a CatalogSource is created.
If publication of the development catalog is broken, restore the mapping or
explicitly select a valid development image for the rehearsal.

## Flow

1. Provision OCP and prepare VM-capable workers using the platform's existing steps.
2. Install/configure the desired storage backend, when additional setup is needed.
3. Install CNV using the selected product build.
4. `cnv-storage-checkup-prepare` waits for CNV, KVM capacity, StorageProfile metadata,
   and CNV-managed golden images. It selects an explicit `CHECKUP_STORAGE_CLASS`,
   otherwise the virtualization default, otherwise the Kubernetes default. A
   missing or ambiguous effective default fails preparation.
5. AWS and GCP use `cnv-storage-checkup-snapshot-sources` to prepare snapshot-backed
   golden images. Azure uses `cnv-storage-checkup-pvc-sources` to prepare
   PVC-backed images and copy-based clones.
6. `cnv-storage-checkup-run` resolves its image from the prepared installed-CSV
   context, creates a dedicated namespace and permissions, and runs the shipped
   checkup through its ConfigMap/Job interface. The Namespace, RBAC, ConfigMap,
   and Job manifests are in the run ref's `CHECKUP_*_MANIFEST` defaults, separate
   from the execution script. The script substitutes only the namespace, image,
   timeout, storage class, and checkup parameters.
7. `cnv-storage-checkup-gather` collects diagnostics and removes the namespace and
   its cluster-reader binding. The platform's post chain then deletes OCP.

## Cloud workflows

`cnv-storage-checkup-{aws,azure,gcp}` compose the common steps with each
platform's existing provisioning and teardown chains. AWS also runs its nested
virtualization enablement step. Each caller supplies the matching
`cluster_profile`, VM-capable instance types, and the `CNV_VERSION` and catalog/
channel inputs required by `cnv-deploy-cnv`. Preparation checks for advertised
KVM capacity rather than relying on the instance type alone.

The product checkup defaults to ten concurrent VMs. The cloud jobs explicitly
use `CHECKUP_NUM_VMS=10` to exercise the concurrent-boot scale check in the
[OpenShift Virtualization CSI certification policy](https://docs.redhat.com/en/documentation/red_hat_software_certification/2026/html/red_hat_openshift_software_certification_policy_guide/assembly-specialized-certifications-for-openshift-badges_openshift-sw-cert-policy-products-managed).
The first AWS ten-VM rehearsal exceeded the EBS per-volume snapshot rate;
four-VM rehearsals passed on AWS, Azure, and GCP, and six-VM rehearsals passed
on Azure and GCP. Those reduced runs established functionality but do not
validate the ten-VM configuration. Worker sizing must account for guest memory,
virtualization overhead, boot-source imports, and CNV.

Each cloud source job asserts its CSI provisioner. On AWS and GCP the snapshot step
patches the selected StorageProfile to use snapshot-backed DataImportCron boot
sources. It waits for every managed golden-image DataSource to reference a ready
VolumeSnapshot before running the checkup. CDI can restore many VM volumes from
one prepared snapshot instead of creating a temporary snapshot of the same
source PVC for each clone.
Azure instead configures PVC-backed golden images and copy-based clones to avoid
the Azure File NFS snapshot restore failure observed during golden-image cloning.
This approach still requires the checkup's separate VM snapshot and restore checks.
The failed AWS run selected `gp3-csi`, whose StorageProfile reported
`cloneStrategy=snapshot` and `dataImportCronSourceFormat=pvc`; its managed
DataSources referenced PVCs.
The separate VM snapshot and restore checks remain required. Ten-VM rehearsals passed on
[AWS](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2119749852416970752),
[Azure](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-azure/2119749854933553152),
and [GCP](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-gcp/2119749857445941248)
with the longer checkup budgets described below. A later
[GCP rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-gcp/2120521427516919808)
verified snapshot-backed golden images and VM snapshot and restore on `standard-csi`.

For ODF or HPP, insert backend installation and default-class configuration
before installing CNV so CDI imports the golden images to the selected backend.
A workflow `pre` override replaces the entire list; include provisioning and
CNV installation in that list as well.

### Live migration coverage

Earlier rehearsals selected `gp3-csi`, `managed-csi`, and `standard-csi`.
Those VM disks were nonshared and the checkup skipped live migration.
The weekly jobs now select storage configured for shared VM disks.

[CDI's StorageClass capabilities](https://github.com/kubevirt/containerized-data-importer/blob/2711c053918b325c1fa0b3981d27e92ec83d63e9/pkg/storagecapabilities/storagecapabilities.go#L78-L95)
include RWX block for AWS EBS `io2` and GCP Hyperdisk, and RWX filesystem for
Azure File (`file.csi.azure.com`).

The `storage-checkup-{aws,azure,gcp}` jobs run Mondays at 03:00,
06:00, and 09:00 UTC respectively. The shared storage setup selects an existing
class or creates one from `CHECKUP_STORAGE_CLASS_PARAMETERS`. For the full
checkup it selects the virtualization default before CNV imports golden images.

- AWS creates `checkup-ebs-io2` with `type: io2` and runs the workers in one
  availability zone for EBS Multi-Attach.
- Azure creates `checkup-azurefile-nfs` using Azure File CSI with NFS and
  `Premium_LRS`. This configuration is a trial following a golden-image import
  failure caused by a permissions change on the default Azure File class.
- GCP runs one shipped checkup on zonal `hyperdisk-balanced`. Three C3
  workers share one zone so the source and destination can attach the same
  RWX Block guest disk during live migration. CDI imports the golden image
  on RWO storage and publishes it through `csi-gce-pd-vsc-images`.
  The checkup boots a VM from that image, exercises volume hotplug and
  unplug, migrates the VM, and snapshots and restores its disks. The same
  invocation also runs the ten-VM boot test.

`CHECKUP_REQUIRE_LIVE_MIGRATION=true` requires the checkup's migration completion
result and a matching KubeVirt success event for the migration in the checkup
namespace. All three jobs require this evidence and a successful
VM snapshot and restore.

The GCP job requires the snapshot of the VM's RWX Block disk to
use `csi-gce-pd-vsc`. Its `vm-disk-snapshots.json` artifact links the VM
snapshot to its boot PVC, access mode, volume mode, and CSI snapshot class.
The runner reads these from the retained checkup resources. The post step
collects artifacts and deletes the checkup namespace. Google documents standard snapshots of
multi-writer Hyperdisks, while the OpenShift storage guide still lists an RWX
snapshot limitation. The GCP rehearsal tests that combination on the installed
payload. [Google Compute Engine release notes](https://docs.cloud.google.com/compute/docs/release-notes#July_18_2025)
and [OpenShift storage guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/storage/understanding-persistent-storage).

## Results and artifacts

The runner requires Job completion, a successful result ConfigMap, and non-skipped
PVC binding, VM boot, clone, hotplug, and concurrent boot results. Migration must
be reported; its capability-dependent outcome is preserved. Add backend-specific
assertions through `CHECKUP_EXPECTED_RESULTS`, a JSON object of result names and
regular expressions. For example, a backend expected to support migration can
require `{"vmLiveMigration":"migration completed"}`. Required missing fields fail
validation, including fields named in this expectations object. Confirm the
shipped product's result schema when defining the job's coverage expectations.

### Main job expectations

Each job that runs the shipped checkup configures `CHECKUP_EXPECTED_RESULTS` to require these complete
lines in the multiline result values:

| Result | Required line |
| --- | --- |
| `status.result.vmSnapshot` | `ReadyToUse=true` |
| `status.result.vmRestore` | `Complete=true` |

Missing, empty, skipped, or unsuccessful snapshot/restore results fail these
expectations. The expressions allow generated resource names, timestamps, and
durations to vary. These checks supplement the runner's required Job completion,
successful overall result, empty failure reason, and core operation results.
They match the result format observed in the successful manual CNV 5.0.0 run.
These jobs require snapshot/restore support from the selected backend. The Monday jobs
set `CHECKUP_EXPECTED_PROVISIONER` to `ebs.csi.aws.com`,
`file.csi.azure.com`, and `pd.csi.storage.gke.io`, respectively. Preparation fails if the selected
class does not use the lane's CSI driver. The resolved class and provisioner
are captured in the run context.

Each job requires a successful migration and VM snapshot and restore. It also
requires positive results for PVC binding, golden-image boot, hotplug and
unplug, and ten concurrent VM boots. The runner requires the checkup's overall
success and an empty failure reason.

### Timeout budgets

Timeout inputs accept positive durations in hours, minutes, or seconds. The VMI
timeout must be shorter than the checkup timeout, which must be shorter than the
Job deadline. The runner allows up to two hours for a hold after namespace, RBAC,
and ConfigMap creation. The Job deadline starts when the Job is created. It is
capped at 2100 seconds to leave at least five minutes for setup and reporting
within the 2h40m runner timeout. Invalid timeouts and result
expressions are rejected before creating checkup resources. Failed API reads
retain the last complete result document so that a failing JUnit report can
still be written.
Job status reads retry transient API failures until the Job deadline and retain
the last complete Job document in the artifacts.

Previous ten-VM rehearsals passed with 20 minutes per VMI operation, 30 minutes
for the checkup, and 2100 seconds for the Job. The current jobs use these budgets.

| Input | Cloud job value |
| --- | --- |
| `CHECKUP_VMI_TIMEOUT` | AWS `6m`, Azure and GCP `3m` |
| `CHECKUP_TIMEOUT` | `10m` |
| `CHECKUP_JOB_TIMEOUT_SECONDS` | `900` (15 minutes) |
| `CHECKUP_PRE_JOB_HOLD_SECONDS` | `7200` (2 hours) |

The first clone of a freshly imported golden image can wait for an EBS snapshot.
In the initial [AWS ten-VM rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118584516665675776),
the first VM booted after about 16 minutes, but four subsequent VMs stalled
while AWS rejected concurrent snapshot requests from the same golden-image EBS
volume. A later [six-VM rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118756154845696000)
hit the same limit. AWS advises
[at least 15 seconds between concurrent snapshots](https://docs.aws.amazon.com/ec2/latest/devguide/errors-overview.html).
The shipped checkup has no setting to space its VM creation requests. A
[four-VM rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118636387866513408)
passed within the 30-minute checkup budget. The AWS snapshot-backed boot-source
setup moves source snapshot creation into the preparation phase. A later ten-VM
rehearsal completed the checkup in 317 seconds with the 30-minute budget. The
default ten-minute budget was tried before this setup and failed while the first
PVC-backed golden-image snapshot was pending. With snapshot-backed boot sources,
the [AWS rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2124828233328234496)
reached live migration, then timed out after three minutes waiting for the VM snapshot.
Each parent job retains a five-hour limit, including installation and teardown.

### Collected artifacts

Artifacts include the installed CSV, cloud, selected class/provisioner, product
versions, result ConfigMap, validation details, JUnit, workload state, checkup
logs, and events. The gather step runs before platform teardown, including on
failure.

Storage diagnostics also include PVs, PVCs, DataVolumes, CDI clone/import sources,
CSI snapshots and snapshot contents, and VM snapshot contents. The golden-image
namespace is collected as well as the checkup namespace because cross-namespace
clones create their source snapshots there. These storage objects are written as
JSON with managed fields and credential-related annotations removed before they
reach the artifact directory. In particular, CDI clone tokens must be removed so
Prow does not discard the whole PVC or DataVolume artifact.

`junit_storage_checkup.xml` reports execution, result validity, each core
operation, and each configured expectation separately. A reported migration
outcome without migration completion is shown as skipped with the original
reason; a stricter migration expectation still fails when completion is required.
Missing or invalid required results produce failed testcases. Setup, execution,
and result-validation failures are distinguished in
`storage-checkup-summary.json`, which also includes the prepared context,
per-check outcomes, and available runtime image IDs from the checkup Pod.
The CSV pullspec and runtime image IDs are retained separately because a
multi-architecture image index can resolve to a different platform digest.

## Initial periodic configuration

The [cloud jobs](../../../../config/openshift/release/openshift-release-main__cnv-storage-checkup.yaml)
use shared profiles, three VM-capable workers per cluster, selected RWX StorageClasses,
and ten checkup VMs. Their schedules are staggered in UTC:

| Job | Profile | Worker type | Expected CSI provisioner | Schedule |
| --- | --- | --- | --- | --- |
| AWS | `openshift-org-aws` | `m8i.4xlarge` | `ebs.csi.aws.com` | Mondays 03:00 UTC |
| Azure | `openshift-org-azure` | `Standard_D16s_v5` | `file.csi.azure.com` | Mondays 06:00 UTC |
| GCP | `openshift-org-gcp` | `c3-standard-8` | `pd.csi.storage.gke.io` | Mondays 09:00 UTC |

The jobs select the OCP 5.1 nightly stream; the CNV development build is
selected separately. Ten-VM rehearsals confirmed driver selection,
snapshot/restore behavior, and post-step cleanup on all three platforms with the
previous 30-minute checkup budget. The shorter default budgets are a new trial.
The GCP PD coverage story [CNV-72113](https://redhat.atlassian.net/browse/CNV-72113)
provides platform test context; [CNV-99261](https://redhat.atlassian.net/browse/CNV-99261)
tracks its integration with this shared CNV checkup. Confirm the final
provisioning and maintenance ownership with the GCP QE owners during review.

Each job adds the existing CNV CI Brew and Konflux credentials to the cluster pull
secret before CNV installation using a helper pinned to a reviewed CNV CI commit.
Generated Prow jobs live under
`ci-operator/jobs/openshift/release/`. Previous four-VM rehearsals passed on
[AWS](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118636387866513408),
[Azure](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-azure/2118706420693078016),
and [GCP](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-gcp/2118706423209660416).
