# HyperShift Jira Agent Workflow

Automated periodic job that processes Jira issues labeled with `issue-for-agent` and creates pull requests using Claude Code.

## Overview

This workflow implements a fully automated system for processing HyperShift Jira issues:

1. **Query**: Searches Jira for unresolved issues in OCPBUGS and CNTRLPLANE projects with label `issue-for-agent`
2. **Process**: For each issue, runs the `/jira-solve` command from the HyperShift repository non-interactively
3. **Track**: Maintains state in a ConfigMap to avoid reprocessing issues
4. **Report**: Generates summary of processed issues and results

## Components

### Workflow
- **File**: `hypershift-jira-agent-workflow.yaml`
- **Description**: Defines the three-phase workflow (pre/test/post)

### Steps

#### 1. Setup (`hypershift-jira-agent-setup`)
- Clones HyperShift repository
- Configures git credentials
- Sets up GitHub CLI authentication
- Verifies Claude Code CLI availability

#### 2. Process (`hypershift-jira-agent-process`)
- Queries Jira API for labeled issues
- Loads processed issues from ConfigMap
- Runs `/jira-solve` for each unprocessed issue using Claude Code CLI
- Implements rate limiting (60s between issues)
- Updates state with results

#### 3. Report (`hypershift-jira-agent-report`)
- Generates summary of processed issues
- Shows recent successes and failures
- Can be extended for notifications

## Configuration

### Secrets Required

The workflow requires two secrets to be created in the `test-credentials` namespace:

1. **`hypershift-jira-agent-anthropic-api-key`**
   - Key: `key`
   - Value: Anthropic API key for Claude Code
   - Mount path: `/var/run/vault/hypershift-jira-agent-anthropic-api-key`

2. **`hypershift-jira-agent-github-token`**
   - Key: `token`
   - Value: GitHub token with PR creation permissions
   - Mount path: `/var/run/vault/hypershift-jira-agent-github-token`

These should be configured in Vault and mounted automatically.

### Periodic Job

Configured in `ci-operator/config/openshift/hypershift/openshift-hypershift-main.yaml`:

```yaml
- as: periodic-jira-agent
  cron: 0 9 * * *  # Daily at 9:00 AM UTC
  steps:
    env:
      JIRA_AGENT_MAX_ISSUES: "1"  # Start with 1 for testing, increase later
    workflow: hypershift-jira-agent
```

### Environment Variables

- **`JIRA_AGENT_MAX_ISSUES`** (default: `10`)
  - Maximum number of issues to process per run
  - Set to `1` initially for safe testing
  - Can be increased to `5`, `10`, or higher once validated
  - Counts both successful and failed processing attempts

### State Management

State is tracked in a ConfigMap:
- **Name**: `hypershift-jira-agent-state`
- **Namespace**: `ci`
- **Data**: `processed` key contains list of processed issues with timestamps and results

Format:
```
ISSUE-KEY TIMESTAMP PR-URL STATUS
OCPBUGS-12345 2025-01-15T10:00:00Z https://github.com/openshift/hypershift/pull/4567 SUCCESS
OCPBUGS-12346 2025-01-15T10:05:00Z - FAILED
```

## How It Works

### Non-Interactive Execution

The workflow uses Claude Code CLI's non-interactive mode:

```bash
echo "/jira-solve ISSUE-KEY origin" | claude -p \
  --output-format json \
  --dangerously-skip-permissions \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch SlashCommand" \
  --max-turns 30
```

This allows the `/jira-solve` command from `.claude/commands/jira-solve.md` in the HyperShift repo to run automatically without user interaction.

### Jira Query

Issues are queried using JQL:
```
project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND labels = issue-for-agent
```

Maximum issues queried and processed is controlled by `JIRA_AGENT_MAX_ISSUES` (default: 10, currently set to 1 for testing).

### Rate Limiting

- 60 seconds between processing each issue
- Maximum 30 agentic turns per issue
- Maximum issues per run: configurable via `JIRA_AGENT_MAX_ISSUES`
- Runs once daily at 9:00 AM UTC

## Container Image

Uses custom image built from `tools/hypershift-jira-agent/Dockerfile` containing:
- Claude Code CLI
- GitHub CLI (gh)
- jq, git, kubectl
- Required dependencies

## Local Testing

Use the test script:

```bash
export ANTHROPIC_API_KEY=your-key
export GITHUB_TOKEN=your-token
./tools/hypershift-jira-agent/test-locally.sh
```

## Monitoring

### Success Indicators
- Issues processed successfully with PRs created
- State ConfigMap updated correctly
- No permission errors

### Failure Indicators
- Failed to authenticate with Claude API
- Failed to create PRs (GitHub auth issues)
- Individual issue processing failures

### Logs
Check Prow job logs for:
- Jira query results
- Processing output for each issue
- PR URLs created
- Error messages

## Maintenance

### Adding/Removing Issues
Add or remove the `issue-for-agent` label in Jira to control which issues are processed.

### Clearing State
To reprocess an issue, remove its line from the ConfigMap:
```bash
kubectl edit configmap hypershift-jira-agent-state -n ci
```

### Adjusting Frequency
Modify the `cron` schedule in the CI config file. Currently runs daily at 9:00 AM UTC.

### Adjusting Issue Limit
Modify the `JIRA_AGENT_MAX_ISSUES` environment variable in the CI config file:
```yaml
env:
  JIRA_AGENT_MAX_ISSUES: "5"  # Increase from 1 to 5
```
Then run `make update` to regenerate job configs.

## Troubleshooting

### Issue: No issues being processed
- Check Jira query returns results
- Verify `issue-for-agent` label exists on issues
- Check state ConfigMap hasn't already marked them processed

### Issue: Authentication failures
- Verify secrets are mounted correctly
- Check API keys are valid and not expired
- Ensure GitHub token has required permissions

### Issue: PR creation fails
- Check GitHub token permissions
- Verify HyperShift repository access
- Review `/jira-solve` command output in logs

## Future Enhancements

- Slack notifications for processed issues
- Metrics push to Prometheus
- Automatic retries for transient failures
- Priority-based processing
- Issue assignment tracking
