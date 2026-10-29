# Step trigger-jobs-post-interop-ocp-watcher-bot-send-message<!-- Omit from TOC. -->
## Table of Contents<!-- Omit from TOC. -->
- [Purpose](#purpose)
- [Requirements](#requirements)
- [Process](#process)

## Purpose
This Step is a post-Step used in conjunction with the `trigger-jobs` Step to send notifications about triggered Jobs via the interop-ocp-watcher-bot.  It
collects job information from the JSON configuration, checks for execution flags, and sends messages through a webhook to notify teams about the status of
triggered Jobs.

## Requirements
This Step consumes configuration from the same JSON structure used by `trigger-jobs`, specifically the `postTaskPars` object when `postTaskStep` is set
to `trigger-jobs-post-interop-ocp-watcher-bot-send-message`. See the [Step configuration file](trigger-jobs-post-interop-ocp-watcher-bot-send-message-ref.yaml)
for the JSON Schema.

The Step also requires credentials mounted at `/tmp/bot_secrets` containing:
- Secret specified by `JT__POST__MENTIONED_GROUP_ID_SECRET_NAME`.
- Secret specified by `JT__POST__WEBHOOK_URL_SECRET_NAME`.

Example of JSON Input:
```json
[
  {
    "trigCond": [...],
    "jobList": [
      {"jobType": "periodic", "jobName": "periodic-ci-some-job", "active": true}
    ],
    "postTask": [
      {
        "postTaskFlgs": 1,
        "postTaskStep": "trigger-jobs-post-interop-ocp-watcher-bot-send-message",
        "postTaskPars": {"postTaskFlag": "watcher-bot"}
      }
    ]
  }
]
```

## Process
This Step will do the following:
 1. Parse the JSON structure from file `${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}`.
 2. For each entry where `postTaskStep` is `trigger-jobs-post-interop-ocp-watcher-bot-send-message`.
 3. Check if the bitwise mask `(postTaskFlgs & JT__POST_TASK_EXEC_FLGS)` evaluates to non-0. If not, skip this post task.
 4. Check post task execution marker (set earlier by `trigger-jobs`) to determine whether this post task is supposed to be executed.
 5. Collect job information for each matching post task entry.
 6. Execute the `interop-ocp-watcher-bot` to send notifications to the configured webhook with information about the triggered Jobs.

For more information about the watcher bot functionality, see https://github.com/CSPI-QE/interop-ocp-watcher-bot.

## Parameters
### `postTaskFlag`
- **Type**: String
- **Required**: No
- **Default**: Step name.
- **Description**: File name (no directory) under `${SHARED_DIR}/` used as execution marker to determine whether this post task should run.
