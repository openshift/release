# Shared Assisted Installer QE infrastructure

`assisted-qe` is a reusable Prow workflow. It provides host allocation integration,
SSH, credential transfer, lifecycle deadlines, cancellation handling and artifact
transport. It does **not** contain a regression marker, a copied Jenkins profile,
Terraform variables, an API/UI test command or ACM deployment logic.

Those responsibilities live in [ocp-edge-ci/ci/prow](https://gitlab.cee.redhat.com/dasulin/ocp-edge-ci/-/tree/MGMT-25680-assisted-qe-prow-framework/ci/prow):

Review the companion implementation in [ocp-edge-ci MR !8919](https://gitlab.cee.redhat.com/ocp-edge-qe/ocp-edge-ci/-/merge_requests/8919).

```text
openshift/release                              ocp-edge-ci
────────────────                              ───────────
test configuration: cron, release, profile ──► profiles/<scenario>.yaml
assisted-qe workflow                           templates/<pipeline>.yaml
  setup → provision → test                    adapters/<pipeline>/*.sh
              ↓                                         ↓
       gather → release                    existing ocp-edge playbooks,
                                           assisted-test-infra and QE tests
```

The two API jobs in
[`openshift-assisted-test-infra-master__qe.yaml`](../../../config/openshift/assisted-test-infra/openshift-assisted-test-infra-master__qe.yaml)
demonstrate reuse. They differ only in profile selection and proposed cron.
The runner supports six current API profiles and a native profile/template
contract for additional pipelines. API is the first concrete adapter; UI and
ACM/ZTP require translation of their own complete job sequences into adapters.
Adding those adapters does not require another SSH workflow.

## Where each existing component goes

| Jenkins component | New location |
| --- | --- |
| `CI/Profile-selector`, `trigger_day`, release selection | Test's `cron` and `releases` here; scheduling policy is explicitly reviewed |
| `job-runner.groovy` | Generic `ocp-edge-ci/ci/prow/runner.py` plus this shared workflow |
| Profile YAML parameters | Existing Jenkins YAML may be imported by an explicit adapter; new profiles can be native runner YAML |
| Groovy pipeline stages | `ocp-edge-ci/ci/prow/adapters/<pipeline>/prepare.sh`, `provision.sh`, `test.sh`, `gather.sh`, `cleanup.sh` |
| Multi-job UI/ACM profile | Template with ordered scripts and per-hook environment values, preserving every required job |
| Cloned repositories and branches | Template `repositories` with pinned commits; test-repo branches remain profile parameters where the adapter supports them |
| Ansible, Terraform, Cypress, pytest | Remain in their current repositories and execute through adapter scripts |
| Jenkins agent | Temporary Prow pod controlling the allocated host over SSH |
| `ocp-ai` lock / sealusa50–53 | Shared Boskos host pool; the physical machines remain where they are |
| Credentials | Common `assisted-qe` / `runner` secret group; adapters declare required filenames |
| Reports | Generic result verification/sanitization; adapter-specific internal Datahub/RP/Polarion publication |

No Groovy interpreter runs in Prow. Unsupported jobs, includes, conditions and
parameters fail validation before destructive pre-clean; the runner never drops
them silently to make an incompatible profile run.

## Add a scheduled profile

Reuse the same workflow with a different profile and reviewed runner revision:

```yaml
- as: saas-api-regression1
  cron: "0 12 * * 3"
  capabilities: [intranet]
  disable_rehearsal: true
  job_queue_name: assisted-qe
  timeout: 18h
  steps:
    workflow: assisted-qe
    leases:
    - resource_type: assisted-qe-host
      env: ASSISTED_QE_HOST
    env:
      QE_OCP_VERSION: "5.0"
      QE_PROFILE: ci/prow/profiles/saas-api-regression1.yaml
      QE_PUBLISH_RESULTS: "false"
      # Set QE_RUNNER_REPO and QE_RUNNER_REF to the reviewed repository/commit.
```

The checked-in consumers contain actual repository and full-commit pins.
During review they reference the companion runner branch's commit on the fork.
Switch them to the upstream repository and merged commit when that MR merges.
The shared queue remains at **capacity 0** until a separate activation change.
Do not copy the workflow or host pool for each profile; otherwise separate
leases could accidentally represent the same physical machine twice.

The current examples target the existing 5.0 API profiles. Other OCP versions
belong in an appropriately versioned config with matching `releases.latest` and
`QE_OCP_VERSION`. Wednesday is retained for the examples, with proposed fixed
times; Jenkins's run-history/retry policy is not reproduced by a cron entry.
Notifications also require an explicit Prow integration decision.

## Common runtime contract

The runner checkout is placed at `WORKSPACE/ocp-edge-ci`; `QE_RUNNER_REF` must be a
full reviewed commit. Hosts require GitLab access, corporate CA trust,
noninteractive sudo and Python >=3.8 with venv support. The generic bootstrap
installs only the runner's YAML dependency. Scenario-specific Python packages,
libvirt, Terraform and test containers belong to adapters.

`QE_SSH_USER` defaults to `kni`, with a home directory at `/home/<user>`.
Every run has `/home/<user>/prow-assisted-qe/run.*`. Engine-generated public
results are fetched after gathering; raw logs/results are retained in
`~/prow-assisted-qe/artifacts/run.*` on the internal host even on reporter failure.
Transferred credentials and temporary checkouts are removed in the release step.
The adapter determines whether clusters/VMs are retained or torn down.

The proposed secret collection/group is `assisted-qe` / `runner`, mounted at
`/var/run/assisted-qe`. The declaration does not create it. Common files:

| File | Purpose |
| --- | --- |
| `ssh-privatekey` | Prow-to-host SSH credential; never copied to the host |
| `known_hosts` | Verified host keys; strict SSH host checking stays enabled |
| `enabled-hosts` | Approved FQDNs, one per line, after exclusive handover |
| Other files | Workload credentials, copied mode 600 to `WORKSPACE/secrets`; each template declares its requirements |

The first API adapter requires `ocm-vault-password` and
`route53-vault-password`, equivalent to the existing Jenkins file credentials.
UI/ACM adapters can declare additional filenames in the same contract. Secret
owners should split workflow credentials/permissions if different consumers
require distinct access; a profile is not an isolation boundary for secrets
mounted into the same pod.

The runner exports the allocated host, OCP version/payload, Prow job/build URL,
workspace, secret directory and repository checkout paths. Profiles/templates
provide the remaining parameters. Full command output and original JUnit stay
internal. Public artifacts contain only numbered case status and generated
revision/phase status JSON. Internal reporters default to off for comparison runs.

Host-side phase deadlines are configurable using `QE_PREPARE_TIMEOUT`,
`QE_PROVISION_TIMEOUT`, `QE_TEST_TIMEOUT`, `QE_GATHER_TIMEOUT` and
`QE_CLEANUP_TIMEOUT`. Keep them below the corresponding step deadlines and leave
time for post steps within the test's overall `timeout`.

## Host ownership and OFCIR

The initial pool represents the four existing `ocp-ai` hosts. A Prow lease does
not coordinate with a Jenkins lock. Drain **all** Jenkins consumers from a host
before enabling it, restrict the Boskos pool to handed-over machines, and add
only those FQDNs to `enabled-hosts`.

The workflow has no hard-coded sealusa hostname restriction; the selected lease
and allowlist define eligible hosts. New pools must represent disjoint physical
resources. ACM profiles that use another host pool must select that pool rather
than being assigned to `ocp-ai` by assumption.

The existing `assisted-ofcir-baremetal` workflow acquires/prepares OFCIR-managed
machines and has its own lifecycle. These four hosts have not been verified as
OFCIR inventory. This change does not claim to register them there. If the team
chooses OFCIR later, adapt the allocation/connection provider while preserving
the same runner/profile contract after agreeing host ownership and release behavior.

On SSH loss, post steps stop the previous remote process group before collecting
or cleaning. Host-side deadlines provide a backstop. If cleanup cannot reach the
host, quarantine it from the pool and investigate remaining rootful containers,
processes and resources before re-use; lease expiration alone is not cleanup.

## Review and activation

1. Review the companion `ocp-edge-ci` runner/templates and existing source parity.
2. Provision credentials and verify connectivity from the assigned build cluster
   to the lab, GitLab, stage service, registries and internal reporting services.
3. Hand over an exclusive host and restrict both the pool and allowlist.
4. Merge the runner, update the consumer pins, and separately enable queue capacity
   **1** for a supervised comparison with `QE_PUBLISH_RESULTS=false`.
5. Verify tests, cancellation, cleanup/retention and reporting; agree cron/retries
   and notifications before retiring the matching Jenkins schedule.

Local checks (do not execute against the lab):

```bash
python3 hack/test_assisted_qe.py
make update
make checkconfig
```

The runner repository has its own profile/lifecycle/result tests. Configuration
and offline tests establish the contract; successful live API/UI/ACM runs still
require the corresponding adapter's supervised validation.
