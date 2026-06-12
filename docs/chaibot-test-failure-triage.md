# Chaibot - Automated Test Failure Triage for Slack

## Overview

Chaibot is an AI-powered extension to the ci-chat-bot service that automatically triages and analyzes OpenShift CI test failures posted in Slack channels. It provides intelligent root cause analysis and actionable recommendations directly in Slack threads.

## Features

### Automatic Detection
- Monitors configured Slack channels (e.g., `#opp-discussion`)
- Detects Prow job failure messages and URLs
- Identifies test failure keywords and patterns

### Intelligent Analysis
- Fetches job logs and artifacts from GCS
- Analyzes failure patterns using AI (OpenAI GPT-4 or Anthropic Claude)
- Categorizes failures into:
  - **Infrastructure Issues**: Cloud provider capacity, networking, timeouts
  - **Flaky Tests**: Race conditions, intermittent failures
  - **Product Bugs**: Panics, assertion failures, regressions
  - **Configuration Issues**: Missing secrets, invalid config

### Historical Context
- Integrates with Sippy to show historical failure patterns
- Searches JIRA for related known issues
- Identifies if this is a new or recurring failure

### Actionable Output
- Posts analysis in Slack threads to keep channels clean
- Provides confidence levels for root cause identification
- Suggests specific next steps (retest, file bug, investigate)
- Includes direct links to logs, Sippy, and related issues

## Example Output

When a test failure is posted in `#opp-discussion`:

```
User: The e2e-aws job is failing again 😞
https://prow.ci.openshift.org/view/gs/origin-ci-test/pr-logs/pull/12345/pull-ci-openshift-installer-master-e2e-aws/678901

---

Chaibot [BOT]: :mag: Analyzing failure... (typically takes 30-60 seconds)

[30 seconds later]

Chaibot [BOT]: :cloud: **Test Failure Analysis**

**Job:** `pull-ci-openshift-installer-master-e2e-aws`
**Status:** Failed after 2h 15m
**Root Cause:** Infrastructure - AWS EC2 Capacity (Confidence: 85%)

**Analysis:**
Test failed during cluster provisioning when attempting to launch EC2 instances in us-east-1c. 
AWS returned "InsufficientInstanceCapacity" error after multiple retry attempts over 45 minutes.

**Evidence:**
```
Error: creating EC2 Instance (i-0a1b2c3d4e5f): InsufficientInstanceCapacity
status code: 500, request id: xyz-123
```

**Historical Pattern:**
This failure has occurred 8 times in the last 24 hours across multiple jobs, all in us-east-1c AZ.
Sippy shows this as a known transient infrastructure issue.

**Recommendations:**
1. ✅ **Retest** - This is a transient AWS issue, likely to succeed on retry
2. 📊 Check AWS Service Health Dashboard for us-east-1 incidents
3. 🔔 If failures persist >6 hours, escalate to infrastructure team

**Related:**
- <https://sippy.dptools.openshift.org/|Sippy Dashboard>
- <https://issues.redhat.com/browse/DPTP-5678|DPTP-5678>: Similar AWS capacity issues

**Classification:** Transient Infrastructure (Not a product bug)

[Buttons: View Logs | Retest | Mark as Known Issue]
```

## Setup and Configuration

### Prerequisites

1. **OpenAI API Key** (or Anthropic API Key)
   - Required for AI-powered analysis
   - Store securely via ci-secret-bootstrap

2. **Slack Channel ID**
   - Get the channel ID for `#opp-discussion`
   - Update in ConfigMap configuration

3. **ci-chat-bot Deployment**
   - Chaibot runs as part of ci-chat-bot service
   - Requires deployment update to enable

### Installation Steps

#### 1. Configure Secrets

Add OpenAI API key via ci-secret-bootstrap:

```bash
# Edit core-services/ci-secret-bootstrap/_config.yaml
# Add entry for chaibot-openai-key pointing to vault path
```

#### 2. Get Slack Channel ID

```bash
# In Slack:
# Right-click #opp-discussion → View channel details → Copy Channel ID
# Update clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml
```

#### 3. Deploy Configuration

```bash
# Create the ConfigMap
oc apply -f clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml

# Create the secrets
# (Managed via ci-secret-bootstrap after PR merge)

# Update ci-chat-bot deployment
# Edit clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml
# Add volumes, volumeMounts, and env vars from chaibot-deployment-patch.yaml
```

#### 4. Update ci-chat-bot Deployment

Apply the changes from `chaibot-deployment-patch.yaml`:

```yaml
# Add to volumes:
- name: triage-config
  configMap:
    name: ci-chat-bot-triage-config

- name: chaibot-secrets
  secret:
    secretName: ci-chat-bot-chaibot-secrets

# Add to volumeMounts (bot container):
- name: triage-config
  mountPath: /etc/triage-config
  readOnly: true

- name: chaibot-secrets
  mountPath: /etc/chaibot-secrets
  readOnly: true

# Add to env (bot container):
- name: CHAIBOT_ENABLED
  value: "true"
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: ci-chat-bot-chaibot-secrets
      key: openai-api-key

# Add to args (bot container):
--enable-triage=true \
--triage-config-path=/etc/triage-config/triage-config.yaml \
```

#### 5. Configure Slack App Permissions

Ensure the ci-chat-bot Slack app has these OAuth scopes:

- `channels:history` - Read messages in public channels
- `channels:read` - View channel information
- `chat:write` - Post messages and replies
- `files:read` - Access uploaded logs
- `reactions:write` - Add reactions to indicate processing

Subscribe to these events:
- `message.channels` - Receive channel messages
- `app_mention` - Respond to @chaibot mentions

#### 6. Deploy and Verify

```bash
# Apply changes
make update
oc apply -f clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml

# Watch deployment
oc rollout status deployment/ci-chat-bot -n ci

# Check logs
oc logs -f deployment/ci-chat-bot -n ci -c bot | grep -i chaibot

# Test in Slack
# Post a test failure message in #opp-discussion with a Prow URL
```

## Usage

### Automatic Triggering

Chaibot automatically responds to messages in monitored channels that contain:
- Prow job URLs (`https://prow.ci.openshift.org/view/gs/...`)
- Failure keywords + context

### Manual Triggering

Mention `@chaibot analyze` with a job URL:

```
@chaibot analyze https://prow.ci.openshift.org/view/gs/origin-ci-test/logs/...
```

### Response Modes

**Thread Mode (default):**
- Posts analysis in a thread reply
- Keeps channels clean and organized

**Reaction Mode:**
- Adds 👀 emoji when processing starts
- Adds ✅ when complete, ❌ if failed

## Configuration

### Adding Channels

Edit `clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml`:

```yaml
monitored_channels:
  - name: "opp-discussion"
    channel_id: "C01234567"
    auto_respond: true
    response_mode: "thread"

  - name: "forum-testplatform"  # Add new channel
    channel_id: "C98765432"
    auto_respond: false  # Require @mention
    response_mode: "thread"
```

### Adjusting Analysis

**Timeout:**
```yaml
analysis:
  timeout: 120  # seconds
```

**AI Model:**
```yaml
analysis:
  ai_provider: "openai"  # or "anthropic"
  model: "gpt-4"         # or "claude-3-opus-20240229"
```

**Failure Categories:**
```yaml
failure_categories:
  custom_category:
    patterns:
      - "specific error pattern"
      - "another pattern"
    confidence_threshold: 0.75
```

### Rate Limiting

```yaml
rate_limiting:
  max_analyses_per_hour: 100
  max_analyses_per_user_per_hour: 10
  cooldown_seconds: 30
```

## Monitoring

### Metrics

Chaibot exposes Prometheus metrics on port 9090:

- `chaibot_messages_processed_total` - Messages evaluated
- `chaibot_failures_detected_total` - Failures identified
- `chaibot_analyses_completed_total` - Analyses finished
- `chaibot_analysis_duration_seconds` - Analysis latency
- `chaibot_api_errors_total` - API errors (Slack, OpenAI, etc.)
- `chaibot_category_detections_total{category="..."}` - Failure categories

### Alerts

PrometheusRules are configured for:
- High error rate (>10% over 5 minutes)
- Analysis timeouts (>120 seconds)
- Service down

View alerts: https://prometheus.ci.openshift.org/

### Dashboards

Grafana dashboard: https://grafana.ci.openshift.org/d/chaibot/

## Troubleshooting

### Chaibot Not Responding

1. **Check service status:**
   ```bash
   oc get pods -n ci -l app=ci-chat-bot
   oc logs -n ci -l app=ci-chat-bot -c bot --tail=100 | grep chaibot
   ```

2. **Verify configuration:**
   ```bash
   oc get configmap ci-chat-bot-triage-config -n ci -o yaml
   ```

3. **Check secrets:**
   ```bash
   oc get secret ci-chat-bot-chaibot-secrets -n ci
   ```

4. **Review metrics:**
   ```bash
   curl http://ci-chat-bot.ci.svc:9090/metrics | grep chaibot
   ```

### Analysis Timeout

If analyses are timing out:
- Check `chaibot_analysis_duration_seconds` metric
- Increase timeout in config
- Reduce `max_log_size_mb` if log fetching is slow
- Check OpenAI API rate limits

### Inaccurate Analysis

- Review AI prompts in `triage-config.yaml`
- Adjust confidence thresholds for categories
- Add more specific patterns to failure categories
- Consider switching AI models or providers

### Rate Limiting Issues

- Check `chaibot_api_errors_total{reason="rate_limit"}`
- Increase OpenAI rate limits
- Adjust `rate_limiting.max_analyses_per_hour`

## Cost Considerations

### OpenAI API Usage

Estimated costs (GPT-4):
- ~$0.03 per analysis (8K input tokens, 2K output tokens)
- 100 analyses/day = ~$3/day = ~$90/month
- Adjust by configuring rate limits

### Optimization

- Use GPT-3.5-turbo for lower cost (~$0.003/analysis)
- Limit `max_log_size_mb` to reduce input tokens
- Configure cooldown to prevent duplicate analyses
- Set per-user rate limits

## Security

### API Keys
- Never commit API keys to git
- Use ci-secret-bootstrap and Vault
- Rotate keys regularly

### Log Access
- Chaibot has read access to GCS buckets
- Only fetches publicly accessible job artifacts
- Does not access private/embargoed job logs

### Slack Permissions
- Only monitors configured public channels
- Cannot read DMs or private channels
- Rate limited to prevent abuse

## Development

### Local Testing

```bash
# Clone ci-tools repo
git clone https://github.com/openshift/ci-tools
cd ci-tools/cmd/ci-chat-bot

# Add chaibot feature flag
# Implement triage module

# Run locally
go run . \
  --triage-config-path=/path/to/triage-config.yaml \
  --enable-triage=true \
  --dry-run
```

### Adding Features

1. Update `triage-config.yaml` schema
2. Implement in ci-tools codebase
3. Add tests
4. Update documentation
5. Submit PR to openshift/ci-tools

## Support

### Documentation
- This guide: https://docs.ci.openshift.org/tools/chaibot/
- ci-chat-bot docs: https://docs.ci.openshift.org/architecture/ci-chat-bot/

### Slack Channels
- `#forum-ocp-testplatform` - Ask questions
- `#forum-ocp-crt` - ci-chat-bot team

### Issues
- Report bugs: https://github.com/openshift/ci-tools/issues
- Feature requests: Same, label with `chaibot`

## Roadmap

Planned features:
- [ ] Multi-turn conversation for deep analysis
- [ ] Automatic JIRA ticket creation for bugs
- [ ] Integration with retester for auto-retry
- [ ] Flaky test database population
- [ ] Weekly failure summary reports
- [ ] Support for analyzing multiple jobs in one request
- [ ] Custom analysis templates per team
