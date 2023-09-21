# trigger-jobs-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Requirements](#requirements)
- [Process](#process)

## Purpose

This ref should be used to trigger groups of jobs using the Gangway API.

## Requirements

This ref consumes data from 2 sources in vault. This data must be stored in the same location as cluster-profile secrets as you will use your cluster_profile to provide the secrets/data needed for this ref.

The two sources of data are:
1. **`gangway-api-token`**: This is something that you need to request from the DPTP team. Once they grant you a token you need to store it under a key named `gangway-api-token` in your vault in the area you store your other cluster_profile secrets for this ref to work.
2. **ENV var `JSON_TRIGGER_LIST`**: This var is used to access a key in vault which holds a JSON blob as its value, you need to create this in the same vault location as the token. Whichever name you give this key in vault must be used as the value for this var.
     - The JSON blob must consist of two thing:
       1. job_name: (string) Name of a periodic job that you wish to trigger using this trigger ref
       2. active: (boolean) whether or not the job should be active, meaning the ref will trigger the job or inactive, meaning the ref will not trigger the job.
- Example of JSON value to store in the jobs-to-trigger key:
``` JSON
[
  {"job_name": "periodic-ci-rhpit-interop-tests-main-slack-poc-cspi-qe-slack-poc-pass", "active": true},
  {"job_name": "periodic-ci-rhpit-interop-tests-main-slack-poc-cspi-qe-slack-poc-fail", "active": false},
  {"job_name": "periodic-ci-rhpit-interop-tests-main-s3-bucket-cleanup-daily-s3-bucket-cleanup", "active": false}
]
```
- Example of naming of vault key and JSON_TRIGGER_LIST var:
  - If you name the secret in vault holding the JSON blob **jobs**
  - Then you will need to assign the **JSON_TRIGGER_LIST** env var the value **jobs**
  - for example here is a test block using this for triggering two different sets of jobs in a config file:
```YAML
tests:
- as: ocp-self-managed-layered-product-interop
  cron: 0 6 * * 1
  steps:
    cluster_profile: aws-cspi-qe
    env:
      JSON_TRIGGER_LIST: self-managed-lp-interop-jobs
    test:
    - ref: trigger-jobs
- as: rosa-sts-hypershift-layered-product-interop
  cron: 0 10 * * 1
  steps:
    cluster_profile: aws-cspi-qe
    env:
      JSON_TRIGGER_LIST: rosa-sts-hypershift-lp-interop-jobs
    test:
    - ref: trigger-jobs
```


## Process

This ref will do the following:
1. Set vars based on path to cluster_profile secrets
2. Test the gangway api to make sure that it is up and returning a 200 status, we will check every minute for one hour, if it never is online the ref will end and fail.
3. Loop through the jobs-to-trigger json, it will trigger each job that has active: true.
4. It will make sure the api curl command returns 200, if not retry up to 3 times. If it fails 3 times it will record the failure and present it to the user in the build-log.txt
5. This process will continue until we have looped through all jobs.
6. Finally it will log the jobs that failed to trigger for the user.

# Possible RFE's
1. Verifying there is a new build for us to use since last week (we will develop this next week).
2. Implementing batching to reduce load on AWS (no timetable for this as we want to learn more before making this change).
3. Add active_until optional value. Use the value as a date, if that value is defined for a job, check the date, if that date has passed, do not trigger.
4. Add active_after optional value. Same idea above, just for starting a job on a certain date.
