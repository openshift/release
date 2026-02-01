# Step trigger-jobs<!-- Omit from TOC. -->
## Table of Contents<!-- Omit from TOC. -->
- [Purpose](#purpose)
- [Requirements](#requirements)
- [Process](#process)

## Purpose
This Step should be used to trigger groups of jobs using the Gangway API.

## Requirements
This Step consumes data from 2 sources from the vault. This data must be stored in the vault path that is synced to `${CLUSTER_PROFILE_DIR}/` like the
Cluster Profile secrets.

The two sources of data are:
 1. The **`gangway-api-token`**: Request from the DPTP team and store under a key named `gangway-api-token` in the vault.
 2. ENV var **`JT__TRIG_JOB_LIST`**: This Env. Var. is used to access a key in vault which holds a JSON structure as its value. See the
    [Step configuration file](trigger-jobs-ref.yaml) for the JSON Schema.
    - Example of JSON value to store in the jobs-to-trigger key:
      ```json
      [
        {
          "trigCond": [
            {
              "trigCondFlgs": 1,
              "trigCondStep": "trigger-jobs-trig-check-resource-owner",
              "trigCondPars": {"trigCondFlag": "cluster-owner", "expOwnerName": "Interop Team"}
            }
          ],
          "jobList": [
            {"jobType": "periodic", "jobName": "periodic-ci-some-job", "active": true}
          ],
          "postTask": [
            {
              "postTaskFlgs": 1,
              "postTaskStep": "trigger-jobs-post-interop-ocp-watcher-bot-send-message",
              "postTaskPars": {"execTaskFlag": "watcher-bot"}
            }
          ]
        },
        {
          "jobList": [
              {"jobType": "periodic", "jobName": "periodic-ci-other-job-1", "active": true},
              {"jobType": "periodic", "jobName": "periodic-ci-other-job-2", "active": false}
          ]
        }
      ]
      ```
    - Legacy example of JSON value to store in the jobs-to-trigger key:
      ```json
      [
        {"job_name": "periodic-ci-rhpit-interop-tests-main-slack-poc-cspi-qe-slack-poc-pass", "active": true},
        {"job_name": "periodic-ci-rhpit-interop-tests-main-slack-poc-cspi-qe-slack-poc-fail", "active": false},
        {"job_name": "periodic-ci-rhpit-interop-tests-main-s3-bucket-cleanup-daily-s3-bucket-cleanup", "active": false}
      ]
      ```
    - Example of naming of vault key and `JT__TRIG_JOB_LIST` Env. Var.:
      If you name the secret in vault holding the JSON blob **job-list**, then you will need to assign the **JT__TRIG_JOB_LIST** Env. Var. the value **job-list**.

      Example test block configuration for triggering 3 sets of Jobs:
      ```yaml
      tests:
      - as: ocp-self-managed-layered-product-interop
        cron: 0 6 * * 1
        steps:
          cluster_profile: aws-cspi-qe
          env:
            JT__TRIG_JOB_LIST: self-managed-lp-interop-jobs
          test:
          - ref: trigger-jobs
      - as: rosa-sts-hypershift-layered-product-interop
        cron: 0 0 * * 5
        steps:
          cluster_profile: aws-cspi-qe
          env:
            JT__TRIG_JOB_LIST: rosa-sts-hypershift-lp-interop-jobs
          test:
          - ref: trigger-jobs
      - as: conditional-trigger-based-on-ownership
        cron: 0 6 * * 1
        steps:
          cluster_profile: metal-redhat-gs
          env:
            JT__TRIG_JOB_LIST: self-managed-lp-interop-jobs
          pre:
          - ref: trigger-jobs-trig-check-resource-owner
          test:
          - ref: trigger-jobs
      ```

### Supported Trigger Condition Steps
- [trigger-jobs-trig-check-resource-owner](trig/check-resource-owner/)

Example of Trigger Condition Step Configuration:
```yaml
ref:
  as: trigger-jobs-trig-some-trigger-condition
  from_image: ...
  commands: trigger-jobs-trig-some-trigger-condition-commands.sh
  env:
  - name: JT__TRIG_JOB_LIST
    documentation: |-
      See documentation of this Env. Var. under the `trigger-jobs` Step.

      JSON Schema for `trigCondPars`:
      ```json
      {
        "trigCondFlag": "<file-name-to-indicate-the-trigger-condition-is-met>", # File name only, no directory.
        ...
      }
      ```
  - name: JT__TRIG_COND_EXEC_FLGS
    documentation: |-
      See documentation of this Env. Var. under the `trigger-jobs` Step.
  - name: JT__TRIG__TC__SOME_ENV_VAR
    documentation: |-
      For Env. Var.s that are specific to this trigger condition Step, prefix it with `JT__TRIG__` plus extra prefix
      specific to this trigger condition, say `TC__` (this secondary prefix should be unique for each trigger condition
      Step).
  resources:
    requests:
      cpu: 10m
      memory: 100Mi
  documentation: |-
    ...
```

Example of Trigger Condition Step Script:
```shell
#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset trigCondStep= trigCondPars=
typeset trigCondName="${HOSTNAME#${JOB_NAME_SAFE}-}"
typeset -i trigCondFlgs=0

while IFS=$'\t' read -r trigCondFlgs trigCondStep trigCondPars; do
    typeset trigCondFlag= expOwnerName=
    ((trigCondFlgs && JT__TRIG_COND_EXEC_FLGS)) || continue
    [ "${trigCondStep}" = "${trigCondName}" ] || continue
    IFS=$'\t' read -r trigCondFlag expOwnerName 0< <(
        echo "${trigCondPars}" |
        jq -cr \
            --arg defVal "${trigCondName}" \
            '[.trigCondFlag//$defVal, .expOwnerName//""] | @tsv'
    )
    ####    Main Logic                                                      ####
     ...
    ############################################################################
done 0< <(jq -cr '
    .[] |
    .trigCond//[] |
    .[] |
    [.trigCondFlgs//0, .trigCondStep//"", (.trigCondPars//{} | @json)] |
    @tsv
' "${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}")

true
```

### Supported Post Task Steps
- [trigger-jobs-post-interop-ocp-watcher-bot-send-message](post/interop-ocp-watcher-bot-send-message/)

Example of Post Task Step Configuration:
```yaml
ref:
  as: trigger-jobs-trig-some-post-task
  from_image: ...
  commands: trigger-jobs-trig-some-post-task-commands.sh
  env:
  - name: JT__TRIG_JOB_LIST
    documentation: |-
      See documentation of this Env. Var. under the `trigger-jobs` Step.

      JSON Schema for `postTaskPars`:
      ```json
      {
        "postTaskFlag": "<file-name-to-indicate-the-post-task-should-be-run>",  # File name only, no directory.
        ...
      }
      ```
  - name: JT__POST_TASK_EXEC_FLGS
    documentation: |-
      See documentation of this Env. Var. under the `trigger-jobs` Step.
  - name: JT__POST__PT__SOME_ENV_VAR
    documentation: |-
      For Env. Var.s that are specific to this post task Step, prefix it with `JT__POST__` plus extra prefix specific
      to this post task, say `PT__` (this secondary prefix should be unique for for each post task Step).
  resources:
    requests:
      cpu: 10m
      memory: 100Mi
  documentation: |-
    ...
```

Example of Post Task Step Script:
```shell
#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset postTaskStep= postTaskPars=
typeset postTaskName="${HOSTNAME#${JOB_NAME_SAFE}-}"
typeset -i dryRun=0 postTaskFlgs=0

[[ "${JOB_NAME}" == 'rehearse-'* ]] && dryRun=1

while IFS=$'\t' read -r postTaskFlgs postTaskStep postTaskPars; do
    typeset execTaskFlag=
    ((postTaskFlgs && JT__POST_TASK_EXEC_FLGS)) || continue
    [ "${postTaskStep}" = "${postTaskName}" ] || continue
    IFS=$'\t' read -r execTaskFlag 0< <(
        echo "${postTaskPars}" |
        jq -cr \
            --arg defVal "${postTaskStep}" \
            '.execTaskFlag//$defVal'
    )
    [ -f "${SHARED_DIR}/${execTaskFlag}" ] || {
        : 'Skipping Job.'
        continue
    }
    ####    Main Logic                                                      ####
     ...
    ############################################################################
done 0< <(jq -cr '
    .[] |
    .postTask//[] |
    .[] |
    [.postTaskFlgs//0, .postTaskStep//"", (.postTaskPars//{} | @json)] |
    @tsv
' "${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}")

true

```


## Process
This Step will do the following:
 1. Set vars based on path to cluster_profile secrets.
 2. **(Optional)** Test the Gangway API to verify availability (skipped by default via `JT__SKIP_HC=true`). When enabled, checks every
    minute for one hour; if the API never comes online, the Step will end and fail.
 3. **(If applicable)** Check trigger conditions written by pre-Steps (e.g., resource ownership). Trigger conditions are only evaluated when
    `(trigCondFlgs && JT__TRIG_COND_EXEC_FLGS)` is evaluated to non-0.
 4. Loop through the jobs-to-trigger JSON and trigger each Job that has `active: true` and matches the set trigger condition, if any.
    Skips triggering the main Job List if `JT__SKIP_TRIG_MAIN_JOBS` is non-zero.
 5. Verify the API call succeeds, retrying up to 3 times on failure. Failed Jobs are recorded and presented in the `build-log.txt`.
 6. **(If applicable)** Set execution markers so the downstream processes can determine whether to execute post-Steps. Markers are only set when
    `(postTaskFlgs && JT__POST_TASK_EXEC_FLGS)` is evaluated to non-0.
 7. Continue processing until all Jobs have been processed.
 8. Log all Jobs that failed to trigger.

## Possible RFEs
 1. Implement batching to reduce load on AWS (no timetable as more learning is needed before making this change).
 2. Add `activeUntil` optional value as a date; when defined for a Job, check the date and do not trigger if the date has passed.
 3. Add `activeAfter` optional value as a date; when defined for a Job, do not trigger until the specified date is reached.
