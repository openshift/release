# Assisted SaaS API regression0: Jenkins → Prow

This is a reviewable migration of the **5.0** profile
`assisted-saas-phase2-api-test-regression-stage-0`. It ports its KVM path;
it does not migrate other versions, UI, ACM/ZTP, VMware, or Nutanix profiles.
The queue capacity is **zero** and rehearsals are disabled. No host should
be used until the cutover requirements below are satisfied.

## What stays where

| Current component | Location after this change | Responsibility |
| --- | --- | --- |
| `CI/Profile-selector` and Wednesday `trigger_day` | [`openshift-assisted-test-infra-master__qe-regression0.yaml`](../../../../config/openshift/assisted-test-infra/openshift-assisted-test-infra-master__qe-regression0.yaml) | Select the 5.0 nightly release and schedule the periodic. |
| `job-runner.groovy`, profile lock, sequential `jobs` | [workflow](assisted-qe-regression0-workflow.yaml), test `leases`, and [Boskos source](../../../../../core-services/prow/02_config/generate-boskos.py) | Lease one host for the entire pre/test/post sequence. |
| Profile YAML plus Groovy parameter defaults | [setup commands](setup/assisted-qe-regression0-setup-commands.sh) | Export the same uppercase variables for Ansible's `lookup('env', ...)`. The defaults are explicit, not a Groovy interpreter. |
| Profile's `Infra/cleanup-all-terraform`, Groovy Init/prepareWorkspace | [setup](setup/assisted-qe-regression0-setup-ref.yaml) | SSH to the leased host, clone reviewed infrastructure revisions, run the existing pre-clean, create the Python environment and Terraform configuration. |
| Groovy KVM cleanup/provision/prepare stages | [provision commands](provision/assisted-qe-regression0-provision-commands.sh) | Call the same Terraform variables and Ansible playbooks. |
| Groovy API test stage | [test commands](test/assisted-qe-regression0-test-commands.sh) | Call the existing `assisted-installer.yaml`; verify the failure marker and JUnit results. |
| Groovy reports/post | [gather commands](gather/assisted-qe-regression0-gather-commands.sh) | Preserve internal reporting and expose sanitized JUnit to Prow. |
| Jenkins agent workspace cleanup/unlock | [release commands](release/assisted-qe-regression0-release-commands.sh) | Stop remaining remote work and remove the temporary workspace/vault files; ci-operator releases the lease. |
| `ocp-edge` playbooks, extravars, Terraform | **Remain in `ocp-edge`** | Cloned on the host to `WORKSPACE/ocp-edge-qe-demo`. |
| `assisted-test-infra` and `kni-assisted-installer-auto/api_tests` | **Remain in their existing repos** | The unchanged Ansible preparation clones them on the host under `/var/tmp/assisted/`, using `master` as today. Resolved commits are recorded. |
| `sealusa50`–`sealusa53` | **Remain physical KVM hosts** | Prow's pod is the SSH controller. Ansible, Terraform, libvirt and rootful Podman/test containers still run on the selected host as `kni` with sudo. |

The YAML `*-ref.yaml` files define the pod image, timeout, credentials and script
for each step. The `*-commands.sh` files contain the commands. Generated jobs
under `ci-operator/jobs/openshift/assisted-test-infra/` are produced by
`make update`; do not edit them manually.

```text
Wednesday periodic (held in queue until cutover)
  → ci-operator pod on an intranet-capable build cluster
  → Boskos leases ONE sealusa host
  → setup → provision → regression0 tests → gather → release
          SSH to the same kni@sealusa host throughout
```

## Source trace and preserved behavior

Reviewed against the upstream sources on 2026-11-26:

- [5.0 profile](https://gitlab.cee.redhat.com/ocp-edge-qe/ocp-edge-ci/-/blob/5dbd6954b12832d886b31ab13d98820a1e5c118c/jenkins/ci-profiles-new/5.0/assisted-saas-phase2-api-test-regression-stage-0.yaml)
- [Groovy pipeline](https://gitlab.cee.redhat.com/ocp-edge-qe/ocp-edge-ci/-/blob/5dbd6954b12832d886b31ab13d98820a1e5c118c/jenkins/jobs/ocp-assisted-installer-pipeline/ocp-assisted-installer-virt-tf.groovy)
- [`ocp-edge` playbooks and Terraform](https://gitlab.cee.redhat.com/ocp-edge-qe/ocp-edge/-/tree/e02f91658e9e3afcc66f6e157b0cc7550a561483)
- [Polarion reporting playbook](https://gitlab.cee.redhat.com/ocp-edge-qe/kni-qe-ci-tools/-/blob/92d81f56057af27987ed0f494b99125d6f90d0bf/ci-polarion-reporting/teflo_reporting.yml)

| Setting | Migrated value |
| --- | --- |
| Service | Existing SaaS stage: `https://api.stage.openshift.com`; no new Assisted service deployment |
| Test selection | `regression0`, three parallel **test workers** |
| VM topology | Three master VMs and two worker VMs; these are different from the three test workers |
| Disks | 120 GB for both master and worker disks |
| CPU/memory | Masters: 16 vCPU/32768 MB; workers: 8 vCPU/16384 MB |
| Network | KVM, IPv4, no VLAN/bond/proxy, existing `qe.lab.redhat.com` defaults |
| OCM identities | `assisted-installer-qe-ci2` and `talhil-aiqe1-u2`, resolved by the existing encrypted vault |
| Polarion | Existing run `OS-20260705-1423` |
| Report Portal | Existing Data Router script and profile launch name |
| Cleanup | Same broad pre-run host cleanup; no new end-of-run KVM VM deletion |
| Host pool | All four hosts in the current `ocp-ai` pool; no invented per-platform split |

The job does not use the `assisted-ofcir-baremetal` workflow: that workflow acquires
and prepares OFCIR-managed infrastructure. These four persistent hosts have not
been verified as OFCIR inventory. Boskos provides Prow-side exclusion for this
migration; it neither provisions a host nor coordinates with Jenkins locks.
If infrastructure owners choose OFCIR, replace the lease/connection contract only
after its actual inventory, credentials and host lifecycle are defined.

## Deliberate differences to review

- **Scheduling:** Wednesday is retained, with an explicit proposed time of
  06:00 UTC. Jenkins scans profiles periodically and considers run history,
  retries and availability; a weekly Prow cron does not reproduce that policy.
  Approve the time and retry policy before activation.
- **Infrastructure revisions:** `ocp-edge-ci`, `ocp-edge`, and the reporting tools
  are pinned to the reviewed commits. Jenkins follows moving `master` revisions.
  The API test repos still follow `master`, matching the profile. Update the pins
  deliberately when infrastructure changes are accepted.
- **Results:** Prow fails on Ansible errors, the `failed` sentinel, failed/error
  JUnit cases, malformed/missing reports, or zero executed tests. This fixes the
  playbook's `ignore_errors` behavior; Jenkins may classify these as UNSTABLE.
  A reporter failure also fails the gather step and is recorded separately.
- **Logs:** public Prow artifacts contain only sanitized case identifiers/status,
  repository revisions and reporter exit codes. Full logs, original XML and test
  artifacts remain on the host and in the existing internal reporting systems.
  `prowgen.private` is not used as an artifact access control.
- **Execution:** the pod uses SSH rather than a persistent Jenkins agent. Each
  run has its own `/home/kni/prow-regression0/run.*` workspace and host-side
  deadlines. Post steps stop the previous process group before reporting/release.
- **Dependencies:** Python venv creation replaces the shared Jenkins helper;
  RHEL 9 keeps Python 3.12 / Ansible 11.9.0 / core 2.18.8, and RHEL 8 keeps the
  Python 3.8 (or 3.6) selection. Corporate CA trust must already be installed.
  The obsolete best-effort Python 3.6 Teflo patch is not applied.
- **Notifications:** Jenkins email, Slack and Jenkins-specific AI analysis are
  not ported here. Choose the supported Prow notification/reporting integration
  with the team before disabling the old scheduled job.

## Credentials and host handover

The proposed GSM collection/group is **`assisted-qe` / `regression0`**, mounted at
`/var/run/assisted-qe`. It must be provisioned by the CI secret owners; declaring
it in a step does not create it. Required files:

| File | Contents/purpose |
| --- | --- |
| `ssh-privatekey` | Key authorized for `kni` on the handed-over hosts |
| `known_hosts` | Verified SSH host keys; strict host checking stays enabled |
| `ocm-vault-password` | Equivalent of Jenkins `ocm-vault-cred` |
| `route53-vault-password` | Equivalent of Jenkins `route53-vault-cred` |
| `enabled-hosts` | One approved FQDN per line; a second gate before destructive pre-clean |

The build cluster must resolve/reach these hosts over SSH. Each host needs its
existing noninteractive sudo, `~/.ssh/id_rsa.pub`, libvirt/Podman prerequisites,
Python tooling, GitLab access, corporate CAs, and access to stage OCM, Quay,
Nexus, Datahub, Report Portal and Polarion. The host's key for provisioned VMs is
separate from the Prow-to-host key. No GitLab credentials or service tokens are
committed in this change.

Before enabling:

1. Review the profile parity and the differences above with Assisted QE/dev and
   the CI owners. Verify the secret collection and reporter dependencies.
2. Pick the initial host, drain it, and remove **all** Jenkins users/locks/jobs
   that can select it. Disabling only the regression0 schedule is insufficient.
   Restrict the Boskos resource list to handed-over hosts, and add precisely those
   FQDNs to `enabled-hosts`. Do not run Jenkins and Prow concurrently on a host.
3. Confirm SSH, DNS, sudo, corporate Git and service reachability from the actual
   selected build cluster. An `intranet` capability is a scheduling request,
   not proof of connectivity to this lab.
4. In a separate activation change, set queue capacity to **1** and first use
   `QE_PUBLISH_RESULTS: "false"` to avoid duplicate external results during
   comparison. Run once under operator supervision; verify test count, topology,
   runtime, logs, failure/cancellation handling and lease release.
5. Verify Datahub, Report Portal and Polarion uploads with publishing enabled,
   agree notifications/retries, then retire the corresponding Jenkins schedule.

If the host is unreachable during post cleanup, quarantine it from the Boskos
pool and investigate before re-use. A lease cannot guarantee remote termination
after loss of network access. Host-side timeouts are a backstop, not a substitute
for checking rootful containers and libvirt after an interrupted run. Preserve
the current VMs for investigation; the next approved run performs pre-clean.

## Validation

From the release repository root:

```bash
python3 hack/test_assisted_qe_regression0.py
make update
make checkconfig
```

Local validation does not execute Ansible, Terraform, SSH or tests on the lab.
End-to-end parity requires the supervised run above; this draft alone cannot
establish credentials, connectivity or successful downstream reporting.
