# Adversary Security Scan — Onboarding Guide

## Overview

The `security-adversary-scan` step runs the adversary security scanner (from `openshift-online/rosa-claude-plugins`, requires org membership) against your repo's source code. It covers 17 security domains: SAST, IaC, containers, Kubernetes, CI/CD, secrets, supply chain, web, API, auth, database, mobile, cloud, performance, git, agent/skill, and critical workflows.

The scan uses Claude Code with the adversary skill from the `rosa-claude-plugins` marketplace. Results are stored as Prow artifacts and optionally posted to Slack.

## Prerequisites

- The `sa-claude-openshift-ci` credential is already available in the `test-credentials` namespace — no setup needed.
- For Slack notifications: request creation of an `adversary-scan-slack-webhook` secret in `test-credentials` containing your team's Slack incoming webhook URL under the key `url`.

## Quick Start — On-Demand PR Scanning

Add to your CI config at `ci-operator/config/<org>/<repo>/<org>-<repo>-<branch>.yaml`:

```yaml
# Add to top of file (create base_images section if it doesn't exist)
base_images:
  claude-ai-helpers:
    name: claude-ai-helpers
    namespace: ci
    tag: latest

# Add to tests array
- always_run: false
  as: adversary-scan
  optional: true
  steps:
    test:
    - ref: security-adversary-scan
```

Run `make update`, then submit a PR to `openshift/release`.

Trigger on any PR with `/test adversary-scan`.

## Scan Modes

| Mode | `ADVERSARY_SCAN_MODE` | Description |
|------|----------------------|-------------|
| Merge ref scan | `merge-ref-scan` (default) | Scans the merge branch / test merge. Exposes PR changes so the scanner focuses on modified files. |
| Full scan | `full-scan` | Scans the entire repo on main. Use for periodic audits. |
| Groundwork | `groundwork` | Full scan with deep codebase analysis. Maps architecture, catalogs code patterns, enumerates API surface, then runs all security phases. Produces an interactive HTML report. |

Override the mode in your CI config:

```yaml
steps:
  env:
    ADVERSARY_SCAN_MODE: full-scan
  test:
  - ref: security-adversary-scan
```

## Adding a Scheduled Scan

Add a periodic job with a `cron:` field:

```yaml
- as: weekly-adversary-scan
  cron: 0 6 * * 6
  steps:
    env:
      ADVERSARY_SCAN_MODE: groundwork
    test:
    - ref: security-adversary-scan
```

Common schedules:

| Schedule | Cron |
|----------|------|
| Every Saturday at 6am UTC | `0 6 * * 6` |
| Every Sunday at midnight UTC | `0 0 * * 0` |
| Weekdays at 2am UTC | `0 2 * * 1-5` |
| First of each month at 6am UTC | `0 6 1 * *` |

## Slack Notifications

Add the `security-adversary-scan-notify` post step to receive Slack notifications:

```yaml
- as: weekly-adversary-scan
  cron: 0 6 * * 6
  steps:
    allow_best_effort_post_steps: true
    env:
      ADVERSARY_SCAN_MODE: groundwork
    test:
    - ref: security-adversary-scan
    post:
    - ref: security-adversary-scan-notify
```

The `allow_best_effort_post_steps: true` ensures the notification runs even if the scan step fails.

Notification colors:

| Condition | Color | Emoji |
|-----------|-------|-------|
| CRITICAL > 0 or HIGH > 0 | Red | :red_circle: |
| MEDIUM > 0 or LOW > 0 (no CRITICAL/HIGH) | Yellow | :large_yellow_circle: |
| All severities = 0 | Green | :large_green_circle: |

## Environment Variable Reference

### Scan Step (`security-adversary-scan`)

| Variable | Default | Description |
|----------|---------|-------------|
| `ADVERSARY_SCAN_MODE` | `merge-ref-scan` | Scan mode (see table above) |
| `CLAUDE_MODEL` | `claude-opus-4-6` | Claude model for the scan |
| `MAX_TURNS` | `100` | Max conversation turns |
| `CLAUDE_CODE_USE_VERTEX` | `1` | Use Vertex AI for authentication |
| `CLOUD_ML_REGION` | `global` | Vertex AI region |
| `ANTHROPIC_VERTEX_PROJECT_ID` | `openshift-ci-prow-agents` | GCP project for Vertex AI |

### Notify Step (`security-adversary-scan-notify`)

| Variable | Default | Description |
|----------|---------|-------------|
| `SLACK_WEBHOOK_PATH` | `/var/run/slack-webhook/url` | Path to file containing the Slack webhook URL |

## Viewing Results

All results are stored as Prow artifacts, accessible from the job link on the PR or the periodic job history.

| Artifact | Description |
|----------|-------------|
| `adversary-scan.log` | Full Claude conversation log |
| `junit_adversary.xml` | JUnit pass/fail for Prow UI |
| `adversary-groundwork-report.html` | Interactive HTML report (groundwork mode only) |

## Example: Complete Config with All Job Types

```yaml
base_images:
  claude-ai-helpers:
    name: claude-ai-helpers
    namespace: ci
    tag: latest

tests:
# On-demand PR scan (merge ref)
- always_run: false
  as: adversary-scan
  optional: true
  steps:
    test:
    - ref: security-adversary-scan

# On-demand full scan
- always_run: false
  as: adversary-scan-full
  optional: true
  steps:
    env:
      ADVERSARY_SCAN_MODE: full-scan
    test:
    - ref: security-adversary-scan

# Weekly groundwork scan with Slack notification
- as: weekly-adversary-scan
  cron: 0 6 * * 6
  steps:
    allow_best_effort_post_steps: true
    env:
      ADVERSARY_SCAN_MODE: groundwork
    test:
    - ref: security-adversary-scan
    post:
    - ref: security-adversary-scan-notify
```

## Modifying the Step

The step-registry files live at `ci-operator/step-registry/security/adversary-scan/`. Changes require approval from the OWNERS listed in that directory. Submit a PR to `openshift/release` with your changes, then run `make update` to regenerate job configs.
