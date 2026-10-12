# Step trigger-jobs-trig-time-eval<!-- Omit from TOC. -->
## Table of Contents<!-- Omit from TOC. -->
- [Purpose](#purpose)
- [Requirements](#requirements)
- [Process](#process)
- [Parameters](#parameters)
- [Examples](#examples)

## Purpose
This Step is a pre-Step used in conjunction with the `trigger-jobs` Step to conditionally trigger Jobs based on time-based evaluations. It provides a generic
mechanism that uses the `date` command with user-supplied parameters and evaluates user-supplied arithmetic expressions to determine whether the trigger
condition is met.

## Requirements
This Step consumes configuration from the same JSON structure used by `trigger-jobs`, specifically the `trigCondPars` object when `trigCondStep` is set
to `trigger-jobs-trig-time-eval`. See the [Step configuration file](trigger-jobs-trig-time-eval-ref.yaml) for the JSON Schema.

Example of JSON Input:
```json
[
  {
    "trigCond": [
      {
        "trigCondFlgs": 1,
        "trigCondStep": "trigger-jobs-trig-time-eval",
        "trigCondPars": {
          "trigCondFlag": "time-condition",
          "datePars": ["+%d"],
          "mathExpr": ["timeVal <= 7"]
        }
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
 1. Parse the JSON structure from file `${CLUSTER_PROFILE_DIR}/${JT__TRIG_JOB_LIST}`.
 2. For each entry where `trigCondStep` is `trigger-jobs-trig-time-eval`.
 3. Check if the bitwise mask `(trigCondFlgs & JT__TRIG_COND_EXEC_FLGS)` evaluates to non-0. If not, skip this trigger condition.
 4. Evaluate the trigger condition using the implemented logic:
    - Execute the `date` command with parameters from `datePars` array and store the result in `${timeVal}`.
    - Evaluate the arithmetic expressions from `mathExpr` array using `let`.
 5. Based on the evaluation result, create or delete the marker file (checked later by `trigger-jobs` and/or post tasks, if applicable) accordingly:
    - If the final evaluation result is non-0 (logical true), create the marker file with `${timeVal}` as content.
    - Otherwise, delete the marker file.

## Parameters
### `trigCondFlag`
- **Type**: String
- **Required**: No
- **Default**: Step name.
- **Description**: File name (no directory) under `${SHARED_DIR}/` to indicate the trigger condition is met.

### `datePars`
- **Type**: Array of Strings - At least 1 non-empty element is required.
- **Required**: Yes
- **Description**: Parameters passed to the `date` command. The output should be an integer and is captured and stored in `${timeVal}`.
- **Examples**:
  - `["+%d"]`                       - Gets current day of month (01-31).
  - `["+%V"]`                       - Gets current ISO week number (01-53).
  - `["-u", "+%H"]`                 - Gets current hour in UTC (00-23).
  - `["-d", "next week", "+%d"]`    - Gets day of month for next week (trick to detect last week of month).

### `mathExpr`
- **Type**: Array of Strings - At least 1 non-empty element is required.
- **Required**: Yes
- **Description**: Arithmetic expressions evaluated using `let` command. The expressions SHOULD reference `${timeVal}`. If the final evaluation result is non-0, the trigger condition is considered met.
- **Examples**:
  - `["timeVal <= 7"]`  - With `datePars=["+%d"]`, triggers if day of month is 1-7.
  - `["timeVal % 2"]`   - With `datePars=["+%V"]`, triggers on odd ISO week numbers.
  - `["timeVal <= 7"]`  - With `datePars=["-d", "next week", "+%d"]`, triggers during last week of month (next week rolls to 1-7).


## Examples
### Example 1: Trigger on first week of month
Trigger jobs only during the first 7 days of each month:
```json
{
  "trigCondFlgs": 1,
  "trigCondStep": "trigger-jobs-trig-time-eval",
  "trigCondPars": {
    "trigCondFlag": "first-week-of-month",
    "datePars": ["+%d"],
    "mathExpr": ["timeVal <= 7"]
  }
}
```

### Example 2: Trigger on even ISO weeks
Trigger jobs only during even-numbered ISO weeks:
```json
{
  "trigCondFlgs": 1,
  "trigCondStep": "trigger-jobs-trig-time-eval",
  "trigCondPars": {
    "trigCondFlag": "even-iso-week",
    "datePars": ["+%V"],
    "mathExpr": ["!(timeVal % 2)"]
  }
}
```

### Example 3: Trigger after 15th of month
Trigger jobs only after the 15th day of the month:
```json
{
  "trigCondFlgs": 1,
  "trigCondStep": "trigger-jobs-trig-time-eval",
  "trigCondPars": {
    "trigCondFlag": "after-mid-month",
    "datePars": ["+%d"],
    "mathExpr": ["timeVal > 15"]
  }
}
```
