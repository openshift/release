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
   checkup through its ConfigMap/Job interface.
6. `cnv-storage-checkup-gather` collects diagnostics and removes the namespace and
   its cluster-reader binding. The platform's post chain then deletes OCP.

## AWS workflow

`cnv-storage-checkup-aws` composes these steps with existing AWS provisioning,
virtualization enablement, and CNV installation. Its caller supplies an AWS
`cluster_profile`, VM-capable instance types, and the `CNV_VERSION` and catalog/
channel inputs required by `cnv-deploy-cnv`. The preparation step checks for
advertised KVM capacity rather than relying on the instance type alone.

The default checkup boots ten concurrent VMs. Worker sizing must account for
their guest memory, virtualization overhead, boot-source imports, and CNV itself.

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

The AWS source job configures `CHECKUP_EXPECTED_RESULTS` to require these complete
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
This main job requires snapshot/restore support from the selected backend.

The selected backend determines the clone strategy and migration capability.
The common policy requires a non-skipped clone result and a reported migration
outcome, accepts capability-dependent migration skips, and propagates checkup
failures. A lane requiring migration completion can add
`"vmLiveMigration": "(^|\\n)VMI \"[^\"]+\" migration completed(\\n|$)"`
to the same expectations object. Keep the snapshot/restore entries when adding
backend requirements: the job supplies the complete object. Review and adapt
this policy when cascading to a release with a different checkup result schema.

Timeout inputs accept positive durations in hours, minutes, or seconds. The VMI
timeout must be shorter than the checkup timeout, which must be shorter than the
Job deadline. The Job deadline is capped at 900 seconds to leave five minutes of
the registry step for setup and reporting. Invalid timeouts and result expressions
are rejected before creating checkup resources. Failed API reads retain the last
complete result document so that a failing JUnit report can still be written.
Job status reads retry transient API failures until the Job deadline and retain
the last complete Job document in the artifacts.

Artifacts include the installed CSV, cloud, selected class/provisioner, product
versions, result ConfigMap, validation details, JUnit, workload state, checkup
logs, and events. The gather step runs before platform teardown, including on
failure.

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

The [AWS job](../../../../config/openshift/release/openshift-release-main__cnv-storage-checkup.yaml)
uses the shared `openshift-org-aws` profile, three `m8i.4xlarge` workers, automatic
StorageClass selection, and ten checkup VMs. Its schedule is daily at
03:00 UTC. The OCP 5.0 nightly baseline follows the manually verified cluster;
the CNV build is selected separately.

The job adds the existing CNV CI Brew and Konflux credentials to the cluster pull
secret before CNV installation using a helper pinned to a reviewed CNV CI commit.
It does not install ODF or HPP. Generated Prow jobs
live under `ci-operator/jobs/openshift/release/`. A CI rehearsal is still required
to verify development-stream installation, AWS execution, diagnostics, and teardown.
