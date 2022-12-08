# (WIP) OpenShift CI Interop Scenario Developers Guide<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
- [PR Process](#pr-process)
  - [Make Update](#make-update)
  - [Rehearsal Job](#rehearsal-job)
- [OpenShift Local](#openshift-local)

## Overview
This guide is meant to be followed by anyone attempting to add an OpenShift interop test scenario to OpenShift CI.

This process will cover the common steps any developer will need to do to work within the scope of the Interop Onboarding Process.

## PR Process
1. Fork the [openshift/release](https://github.com/openshift/release) repo
2. Git clone forked repo using ssh (Do not clone with HTTP)
3. Create branch
4. Make your changes
5. Run [make update](#make-update) from root of release repo
6. Git add changed files
7. Git commit -m 'commit message'
8. Git push origin {branch name}
9. Submit PR from UI
10. Run [rehearsal job](#run-rehearsal-job) (if needed).

### Make Update
Running make update provides many different checks to ensure your changes follow the standards of the release repo. When you fail the make update command you are given output describing where the problem lies and how to fix it.

If you create/update a ci-operator/config file it will:
- Create/update the Prow job for that specific config file (Prow jobs never need to be changed manually).
  - See [make jobs](https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/#generating-prow-jobs-from-ci-operator-configuration-files) docs which will run as part of the make update command.
- Create/update metadata and store it in the config file at the bottom of the file.

### Rehearsal Job
A rehearsal job is meant to execute a prow job to prove that your changes are valid prior to merging. Not all PRs will require rehearsals, the `openshift-ci-robot` will comment on your PR alerting you that a rhearsable test has been affected by your change.

 **Make sure that you review the affected jobs and only run the rehearsal if you know the jobs that will execute are the ones you are targetting. We don't want to actually run other teams jobs which will use their infra and accrue unecessary costs.**

Simply add a comment to your PR that says `/pj-rehearse` (pj = prow job) to trigger the rehearsal job. Once the job starts (after 1-2 min) you'll see the job in the automated checks at the bottom of the PR.

## OpenShift Local
TODO undecided if we want to provide specific steps for executing scripts from local containers built using PQEs images.