# Chaibot Test Failure Triage Extension

This directory contains configuration for the **Chaibot** test failure triage feature, an AI-powered extension to ci-chat-bot.

## What is Chaibot?

Chaibot automatically monitors Slack channels (like `#opp-discussion`) for test failure messages, analyzes the failures using AI, and posts detailed triage analysis in threads.

## Files

- `triage-config.yaml` - Main configuration for Chaibot (source of truth)
- `workflows-config.yaml` - Cluster provisioning workflows (existing ci-chat-bot config)

## Quick Start

### 1. Prerequisites

- OpenAI API key (stored in ci-secret-bootstrap)
- Slack channel ID for #opp-discussion
- ci-chat-bot deployment with Chaibot support (requires ci-tools update)

### 2. Configuration

The `triage-config.yaml` file is mounted as a ConfigMap in the ci-chat-bot deployment.

To enable Chaibot:

```yaml
enabled: true

monitored_channels:
  - name: "opp-discussion"
    channel_id: "YOUR_CHANNEL_ID"  # Get from Slack
    auto_respond: true
```

### 3. Get Slack Channel ID

In Slack:
1. Right-click the `#opp-discussion` channel
2. Select "View channel details"
3. Copy the Channel ID from the About section
4. Update `channel_id` in `triage-config.yaml`

### 4. Deploy

The configuration is automatically deployed when you:

```bash
# Update from this directory
make update

# Apply ConfigMap (done automatically by postsubmit)
oc apply -f ../../clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml
```

## How It Works

1. **Detection**: Monitors configured Slack channels for messages containing:
   - Prow job URLs
   - Failure keywords ("test failed", "job failed", etc.)

2. **Analysis**: When a failure is detected:
   - Fetches job logs from GCS
   - Analyzes with AI (OpenAI GPT-4)
   - Categorizes failure (infrastructure, flaky, bug, config)
   - Searches Sippy for historical patterns
   - Looks up related JIRA issues

3. **Response**: Posts analysis in thread:
   - Root cause with confidence level
   - Evidence from logs
   - Historical context
   - Actionable recommendations

## Example

User posts in #opp-discussion:
```
Job failed again: https://prow.ci.openshift.org/view/gs/origin-ci-test/logs/...
```

Chaibot responds in thread:
```
:cloud: Test Failure Analysis

Root Cause: Infrastructure - AWS Capacity (85% confidence)
Analysis: Instance launch failed due to InsufficientInstanceCapacity in us-east-1c
Evidence: "Error: creating EC2 Instance: InsufficientInstanceCapacity..."
Historical: 8 similar failures in last 24h (transient issue)
Recommendation: Retest - likely to succeed

Classification: Transient Infrastructure Issue
```

## Configuration Options

### Monitored Channels

Add or remove channels:

```yaml
monitored_channels:
  - name: "opp-discussion"
    channel_id: "C01234567"
    auto_respond: true      # Auto-analyze or require @mention
    response_mode: "thread" # thread, channel, or dm
```

### Analysis Settings

Adjust AI provider and timeout:

```yaml
analysis:
  timeout: 120          # seconds
  ai_provider: "openai" # openai or anthropic
  model: "gpt-4"        # or gpt-3.5-turbo for lower cost
```

### Failure Categories

Customize or add categories:

```yaml
failure_categories:
  infrastructure:
    patterns:
      - "InsufficientInstanceCapacity"
      - "RequestLimitExceeded"
    confidence_threshold: 0.7
```

### Rate Limiting

Prevent abuse:

```yaml
rate_limiting:
  max_analyses_per_hour: 100
  max_analyses_per_user_per_hour: 10
  cooldown_seconds: 30  # Min time between analyses for same job
```

## Integrations

### Sippy

Enabled by default, shows historical failure patterns:

```yaml
integrations:
  sippy:
    enabled: true
    base_url: "https://sippy.dptools.openshift.org"
    lookback_days: 7
```

### JIRA

Searches for related issues:

```yaml
integrations:
  jira:
    enabled: true
    endpoint: "https://redhat.atlassian.net"
    search_projects: ["OCPBUGS", "DPTP"]
```

### OpenAI

AI analysis requires API key:

```yaml
integrations:
  ai_api:
    enabled: true
    secret_name: "chaibot-openai-key"
    secret_namespace: "ci"
    rate_limit_rpm: 50
```

## Monitoring

Metrics exposed on port 9090 (same as ci-chat-bot):

- `chaibot_messages_processed_total`
- `chaibot_failures_detected_total`
- `chaibot_analyses_completed_total`
- `chaibot_analysis_duration_seconds`
- `chaibot_api_errors_total`

Alerts configured in `clusters/app.ci/ci-chat-bot/chaibot-deployment-patch.yaml`

## Troubleshooting

### Chaibot not responding

```bash
# Check if enabled
oc get configmap ci-chat-bot-triage-config -n ci -o yaml | grep enabled

# Check logs
oc logs -n ci deployment/ci-chat-bot -c bot | grep -i chaibot

# Verify secrets exist
oc get secret ci-chat-bot-chaibot-secrets -n ci
```

### Analysis timeout

- Check `max_log_size_mb` - reduce if logs are too large
- Increase `analysis.timeout` value
- Check OpenAI API status

### Wrong analysis

- Review and tune `failure_categories` patterns
- Adjust `confidence_threshold` values
- Update AI prompts in `ai_prompts` section

## Cost Management

OpenAI API costs (approximate):
- GPT-4: ~$0.03 per analysis
- GPT-3.5-turbo: ~$0.003 per analysis

At 100 analyses/day:
- GPT-4: ~$90/month
- GPT-3.5-turbo: ~$9/month

Control costs with:
- Rate limiting
- Cooldown periods
- Switching to GPT-3.5-turbo

## Development

To add new features:

1. Update `triage-config.yaml` schema
2. Implement in [openshift/ci-tools](https://github.com/openshift/ci-tools) cmd/ci-chat-bot
3. Add tests
4. Update this documentation

## Support

- Questions: `#forum-ocp-testplatform`
- ci-chat-bot team: `#forum-ocp-crt`
- Issues: https://github.com/openshift/ci-tools/issues
- Docs: https://docs.ci.openshift.org/tools/chaibot/

## Related

- [ci-chat-bot README](README.md) - Cluster provisioning workflows
- [Chaibot Full Documentation](../../docs/chaibot-test-failure-triage.md)
- [Sippy](https://sippy.dptools.openshift.org/) - Test analysis platform
- [ci-tools](https://github.com/openshift/ci-tools) - Source code
