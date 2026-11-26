# Assisted QE SSH hostname POC

This optional job checks one connection: a CI step pod SSHes to an existing QE
machine and runs `hostname`. The result appears in the step log. It does not
allocate, provision, or reimage a machine.

The job definition is in
[`openshift-assisted-test-infra-master__ssh-poc.yaml`](../../../../config/openshift/assisted-test-infra/openshift-assisted-test-infra-master__ssh-poc.yaml).
This directory contains the step definition and the command it runs.

## Before running

1. Confirm that `kni@sealusa50.kni.eng.rdu2.dc.redhat.com` is the intended
   target. The matching public key must be authorized for that account.
2. The `assisted-installer-ci-secret` Rover group owns the existing
   `edge-group` Google Secret Manager collection. Create a new
   `assisted-qe-ssh-poc` group with these three fields:

   | Field | Content |
   | --- | --- |
   | `ssh-privatekey` | Private key authorized on the target machine. |
   | `ssh-hostname` | `sealusa50.kni.eng.rdu2.dc.redhat.com` (no username). |
   | `known-hosts` | Host-key entry verified with the machine administrator. |

   For example, with the [Secret Manager CLI](https://docs.ci.openshift.org/architecture/cli-secret-manager/#creating-a-new-secret/):

   ```sh
   sm create -c edge-group assisted-qe-ssh-poc/ssh-privatekey --from-file=/path/to/approved/private-key
   sm create -c edge-group assisted-qe-ssh-poc/ssh-hostname --from-literal=sealusa50.kni.eng.rdu2.dc.redhat.com
   sm create -c edge-group assisted-qe-ssh-poc/known-hosts --from-file=/path/to/verified/known-hosts
   ```

   The step sees these as files under `/var/run/assisted-ssh-poc`. This PR
   creates none of the secret values. The mount path may resemble the older
   Vault path in other jobs, but this step uses Google Secret Manager.
3. Confirm that a build cluster with the `intranet` capability can resolve
   the hostname and reach its SSH port.

Rehearsal is disabled while the credentials are pending. Once the config is
merged into `openshift/release`, an authorized user can trigger the job on a PR
against `master` in `openshift/assisted-test-infra` with
`/test ssh-poc-ssh-hostname`. There is no schedule. To test before merging,
remove `disable_rehearsal: true` after the credentials and network are ready.
