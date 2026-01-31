# Step trigger-jobs-trig-check-resource-owner<!-- Omit from TOC. -->
## Table of Contents<!-- Omit from TOC. -->
- [Purpose](#purpose)
- [Requirements](#requirements)
- [Process](#process)
- [Current Implementation](#current-implementation)
- [Planned Implementation](#planned-implementation)

## Purpose
This Step is a pre-Step used in conjunction with the `trigger-jobs` Step to conditionally trigger Jobs based on resource ownership. It determines the current
owner of a resource and creates or deletes an ownership flag file under `${SHARED_DIR}/`, which the `trigger-jobs` Step checks for its existence to decide
whether to trigger specific Jobs.

## Requirements
This Step consumes configuration from the same JSON structure used by `trigger-jobs`, specifically the `trigCondPars` object when `trigCondStep` is set
to `trigger-jobs-trig-check-resource-owner`. See the [Step configuration file](trigger-jobs-trig-check-resource-owner-ref.yaml) for the JSON Schema.

Example configuration in vault:
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
    "postTask": [...]
  }
]
```

## Process
This Step will do the following:
 1. Parse the JSON file specified by `${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}`.
 2. For each entry where `trigCondStep` is `trigger-jobs-trig-check-resource-owner`, extract the `trigCondFlag` and `expOwnerName` parameters.
 3. Determine the current resource owner using the implemented ownership logic.
 4. Write the current resource owner to `${SHARED_DIR}/${trigCondFlag}`, or delete the file, based on the ownership logic.
 5. The `trigger-jobs` Step checks for its existence to decide whether to trigger the associated Jobs.

## Current Implementation
**Status**: Placeholder implementation using ISO week number parity.

The current implementation alternates ownership between two teams on a weekly basis using ISO week numbers:
- **Odd-numbered ISO weeks**: Deletes the ownership file (to skip Jobs).
- **Even-numbered ISO weeks**: Writes `${expOwnerName}` to the ownership file (to trigger Jobs).

## Planned Implementation
The future implementation will fetch the actual resource ownership schedule from a URL using a dedicated container image. This will allow for more
flexible ownership schedules that are not limited to simple weekly alternation and can be managed externally through a centralized ownership calendar or
API.
