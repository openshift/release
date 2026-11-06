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
5. `cnv-storage-checkup-run` resolves its image from the prepared installed-CSV
   context, creates a dedicated namespace and permissions, and runs the shipped
   checkup through its ConfigMap/Job interface. The Namespace, RBAC, ConfigMap,
   and Job manifests are in the run ref's `CHECKUP_*_MANIFEST` defaults, separate
   from the execution script. The script substitutes only the namespace, image,
   timeout, storage class, and checkup parameters.
6. `cnv-storage-checkup-gather` collects diagnostics and removes the namespace and
   its cluster-reader binding. The platform's post chain then deletes OCP.

## Cloud workflows

`cnv-storage-checkup-{aws,azure,gcp}` compose the common steps with each
platform's existing provisioning and teardown chains. AWS also runs its nested
virtualization enablement step. Each caller supplies the matching
`cluster_profile`, VM-capable instance types, and the `CNV_VERSION` and catalog/
channel inputs required by `cnv-deploy-cnv`. Preparation checks for advertised
KVM capacity rather than relying on the instance type alone.

The product checkup defaults to ten concurrent VMs. The first AWS ten-VM
rehearsal exceeded the EBS per-volume snapshot rate; four VMs passed on AWS,
Azure, and GCP. The current jobs set `CHECKUP_NUM_VMS=6` to test additional
concurrent-boot capacity on each platform. Rehearsals must establish whether
six VMs fit each provider's storage and worker limits. Worker sizing must
account for guest memory, virtualization overhead, boot-source imports, and CNV.

For ODF or HPP, insert backend installation and default-class configuration
before checkup preparation. A workflow `pre` override replaces the entire list;
include the provisioning and CNV installation steps in that list as well.

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

Each cloud source job configures `CHECKUP_EXPECTED_RESULTS` to require these complete
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
These jobs require snapshot/restore support from the selected backend. Azure and
GCP also set `CHECKUP_EXPECTED_PROVISIONER` to `disk.csi.azure.com` and
`pd.csi.storage.gke.io`, respectively. Automatic default-class selection remains
enabled; preparation fails if the selected class does not use the lane's CSI
driver. The resolved class and provisioner are captured in the run context.

The selected backend determines the clone strategy and migration capability.
The common policy requires a non-skipped clone result and a reported migration
outcome, accepts capability-dependent migration skips, and propagates checkup
failures. A lane requiring migration completion can add
`"vmLiveMigration": "(^|\\n)VMI \"[^\"]+\" migration completed(\\n|$)"`
to the same expectations object. Keep the snapshot/restore entries when adding
backend requirements: the job supplies the complete object. Review and adapt
this policy when cascading to a release with a different checkup result schema.

### Timeout budgets

Timeout inputs accept positive durations in hours, minutes, or seconds. The VMI
timeout must be shorter than the checkup timeout, which must be shorter than the
Job deadline. The Job deadline is capped at 2100 seconds to leave five minutes of
the 40-minute registry step for setup and reporting. Invalid timeouts and result
expressions are rejected before creating checkup resources. Failed API reads
retain the last complete result document so that a failing JUnit report can
still be written.
Job status reads retry transient API failures until the Job deadline and retain
the last complete Job document in the artifacts.

The shared defaults remain three minutes per VMI operation, ten minutes for the
checkup, and 900 seconds for the Job. Each cloud source job supplies longer budgets:

| Input | Cloud job value |
| --- | --- |
| `CHECKUP_VMI_TIMEOUT` | `20m` |
| `CHECKUP_TIMEOUT` | `30m` |
| `CHECKUP_JOB_TIMEOUT_SECONDS` | `2100` (35 minutes) |

The first clone of a freshly imported golden image can wait for an EBS snapshot.
In the latest [AWS rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118584516665675776),
the initial VM booted after about 16 minutes, but four of ten subsequent VMs
stalled while AWS rejected concurrent snapshot requests from the same golden
image EBS volume. AWS documents this as a per-volume rate limit and advises
[at least 15 seconds between concurrent snapshots](https://docs.aws.amazon.com/ec2/latest/devguide/errors-overview.html).
The shipped checkup has no setting to space its VM creation requests. A
subsequent
[AWS rehearsal](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118636387866513408)
passed with four VMs within the 30-minute checkup budget.
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
use shared profiles, three VM-capable workers per cluster, automatic StorageClass
selection, and six checkup VMs. Their schedules are staggered in UTC:

| Job | Profile | Worker type | Expected CSI provisioner | Schedule |
| --- | --- | --- | --- | --- |
| AWS | `openshift-org-aws` | `m8i.4xlarge` | Recorded from the effective default | Daily 03:00 |
| Azure | `openshift-org-azure` | `Standard_D16s_v5` | `disk.csi.azure.com` | Daily 06:00 |
| GCP | `openshift-org-gcp` | `n2-standard-8` | `pd.csi.storage.gke.io` | Daily 09:00 |

The OCP 5.0 nightly baseline follows the manually verified cluster; the CNV
build is selected separately. Four-VM rehearsals confirmed Azure and GCP driver
selection, snapshot/restore behavior, and post-step cleanup. The six-VM setting
still needs a rehearsal on each platform before it is treated as validated.
The GCP PD coverage story [CNV-72113](https://redhat.atlassian.net/browse/CNV-72113)
provides platform test context; [CNV-99261](https://redhat.atlassian.net/browse/CNV-99261)
tracks its integration with this shared CNV checkup. Confirm the final
provisioning and maintenance ownership with the GCP QE owners during review.

Each job adds the existing CNV CI Brew and Konflux credentials to the cluster pull
secret before CNV installation using a helper pinned to a reviewed CNV CI commit.
It does not install ODF or HPP. Generated Prow jobs live under
`ci-operator/jobs/openshift/release/`. Previous four-VM rehearsals passed on
[AWS](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-aws/2118636387866513408),
[Azure](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-azure/2118706420693078016),
and [GCP](https://prow.ci.openshift.org/view/gs/test-platform-results-public/pr-logs/pull/openshift_release/87544/rehearse-87544-periodic-ci-openshift-release-main-cnv-storage-checkup-storage-checkup-gcp/2118706423209660416).
