# Assisted Installer QE Prow POC

This is a standalone, unmerged proof of concept. All new orchestration lives in
this repository as native ci-operator workflows, steps and job configuration.
The jobs are disabled through the `assisted-qe` queue's **capacity 0**.

## Layout

```text
ci-operator/config/openshift/assisted-test-infra/
  openshift-assisted-test-infra-master__qe.yaml   # schedules and scenario parameters
ci-operator/step-registry/assisted/qe/
  assisted-qe-workflow.yaml                     # common host lifecycle
  setup/                                       # SSH, workspace, secrets, helpers
  gather/                                      # sanitized JUnit artifacts
  release/                                     # stop processes, archive, remove credentials
  saas/api/
    assisted-qe-saas-api-workflow.yaml           # compose common and API steps
    prepare/                                   # checkout, parameters, dependencies
    provision/                                 # Terraform and host preparation
    test/                                      # Ansible API entry point and result check
```

The generic workflow supplies host access and post steps. The API workflow
demonstrates how a pipeline composes those shared steps:

```text
Prow cron + steps.env
          ↓
setup → API prepare → API provision → API test → gather → release
  │         │               │            │
  └── temporary Prow pods use SSH to execute on the leased host ──┘
```

The Prow pod is the controller. Commands sent through `qe_remote` run on the
leased host. Repository checkouts, Ansible, Terraform and test containers are
there; the host does not become a Prow worker node.

## A profile is a test configuration

The [checked-in examples](../../../config/openshift/assisted-test-infra/openshift-assisted-test-infra-master__qe.yaml)
select two test markers through the same API workflow. There is no separate
profile parser or custom job runner. For example:

```yaml
- as: saas-api-regression1
  cron: "0 12 * * 3"
  capabilities: [intranet]
  disable_rehearsal: true
  job_queue_name: assisted-qe
  max_concurrency: 1
  timeout: 18h
  steps:
    workflow: assisted-qe-saas-api
    leases:
    - resource_type: assisted-qe-host
      env: ASSISTED_QE_HOST
    env:
      QE_OCP_VERSION: "5.0"
      PROFILE_NAME: saas-api-regression1
      ASSISTED_TEST_INFRA_MARKER: regression1
      ASSISTED_FUNCTIONAL_API_TESTS_PARALLEL: "3"
      MASTER_DISK_SIZE: "120"
      WORKER_DISK_SIZE: "120"
```

Common API inputs and defaults are declared in
[the prepare step](saas/api/prepare/assisted-qe-saas-api-prepare-ref.yaml).
The step explicitly exports those parameters to a private `job.env` on the
host. Fixed API-specific settings are in its `api.env` heredoc. Other steps
source these files, so Ansible's environment lookups receive the same values.
To add a configurable input, declare it in the ref and add it to `qe_export`.

`cron` is the scheduler. These Wednesday times are proposed POC schedules.
`releases.latest` selects the OCP payload; `QE_OCP_VERSION` must match it.
Retry policy, production schedules and notifications are outside this POC.

## Repository checkouts and commands

The API prepare step clones `OCP_EDGE_REPO` into the private host workspace and
checks out the full commit in `OCP_EDGE_REF`. This existing repository supplies
the Ansible playbooks, extravars, templates and Terraform files. Its test
automation clones `assisted-test-infra` and `kni-assisted-installer-auto` using
the branches selected by the Prow parameters. These are workload dependencies;
all POC orchestration and parameters are reviewable in this PR.

The API example targets KVM with a stage endpoint, three masters, two workers
and 120-GiB disks. It requires a clean, exclusively assigned host. It does not
run a general lab-reset script. Provisioning handles its API VMs, prior Terraform
state and the network preparation playbooks. VMs are retained for investigation
after the test; the release step removes only the temporary run workspace.

Results must contain executed, passing JUnit cases. A failure marker, failed
tests, malformed XML or missing/empty/all-skipped results fail the API step.
Gathering uploads only numbered case statuses. Original XML, logs and checkout
revision information stay under `~/prow-assisted-qe/artifacts/run.*` on the host.
Datahub, Report Portal and Polarion publication are outside this POC.

## Reuse for UI or ACM

Add normal step-registry refs for the required provisioning and test commands,
then compose them with the shared setup/gather/release refs. An ordered `pre`
list can express hub installation followed by spoke installation. A `post`
list can collect scenario-specific diagnostics and tear down resources before
the common gather/release steps. The UI and ACM pipelines are not implemented
by this POC.

A new step uses the same remote execution helper:

```bash
#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
qe_export MY_PARAMETER
qe_remote my-step 30m <<'REMOTE'
# Commands here run on the leased host, with WORKSPACE and exported parameters.
# Clone the workload repository, then execute its actual command.
# Write JUnit to "$WORKSPACE/results" and check it after the tests:
"$QE_PYTHON" "$WORKSPACE/results.py" check "$WORKSPACE"
REMOTE
```

Declare `MY_PARAMETER`, the image, credentials and a suitable step timeout in
that step's ref YAML. This is an extension example, not a completed workload.
Host-side deadlines must fit inside their step and whole-job deadlines.

## Hosts, credentials and a supervised run

The proposed Boskos pool represents sealusa50–53. The pool and `enabled-hosts`
allowlist must contain only exclusively handed-over machines. Boskos leases do
not coordinate with other schedulers. Other physical pools must use distinct
resources; UI or ACM should not be assigned these machines by assumption.
This POC does not register hosts in OFCIR.

The `assisted-qe` / `runner` credential group must be provisioned separately:

| File | Purpose |
| --- | --- |
| `ssh-privatekey` | Prow-to-host key; remains in the pod |
| `known_hosts` | Verified host keys for strict checking |
| `enabled-hosts` | Approved host FQDNs, one per line |
| `ocm-vault-password` | API automation vault credential |
| `route53-vault-password` | DNS automation vault credential |

Workload credential files are transferred with private permissions and removed
on release. The shared group is not an isolation boundary between scenarios;
use separate credential groups when workloads require different permissions.

Hosts require corporate network/CA access, Git, Python, noninteractive sudo and
the relevant KVM/test prerequisites. The API environment uses the RHEL-specific
Python/Ansible setup in the prepare script. No live end-to-end run is claimed.

Before any supervised run: verify build-cluster connectivity, prepare the
credentials, hand over one clean host, restrict the pool/allowlist to it and
explicitly enable queue capacity 1. Exercise cancellation and result collection
as well as the test itself. If the host becomes unreachable, quarantine it and
inspect remaining processes/resources before reuse; lease expiration is not
host cleanup.

## Offline validation

```bash
python3 hack/test_assisted_qe.py
make update
make checkconfig
make check-boskos
```

These checks validate configuration, parameter transfer, remote timeouts,
cancellation, credential removal and JUnit handling without contacting the lab.
