# Chaibot Deployment Guide

## Status

✅ Configuration files created  
✅ ci-chat-bot deployment updated with Chaibot volumes and mounts  
⚠️ Requires: Slack channel ID and OpenAI API key  
⚠️ Requires: Code implementation in openshift/ci-tools  

## What's Ready

All configuration and deployment files are prepared:

```
✓ core-services/ci-chat-bot/triage-config.yaml
✓ clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml
✓ clusters/app.ci/ci-chat-bot/chaibot-deployment-patch.yaml
✓ clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml (UPDATED)
✓ docs/chaibot-test-failure-triage.md
```

## Prerequisites

### 1. Get Slack Channel ID for #opp-discussion

In Slack:
1. Right-click `#opp-discussion` channel
2. Select "View channel details"
3. Scroll down in the About section
4. Copy the Channel ID (format: `C` followed by alphanumeric, e.g., `C01234ABCD`)

### 2. Get OpenAI API Key

Option A - New Key:
1. Go to https://platform.openai.com/api-keys
2. Create new secret key
3. Copy the key (starts with `sk-`)
4. **Important**: Save it securely - you can't view it again

Option B - Use Existing:
If your organization already has a key in Vault, confirm the path.

### 3. Verify Cluster Access

```bash
# Login to app.ci cluster
oc login https://api.ci.l2s4.p1.openshiftapps.com:6443

# Verify access to ci namespace
oc get pods -n ci
```

## Deployment Steps

### Step 1: Update Slack Channel ID

```bash
# Edit the ConfigMap with the actual channel ID
vi clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml

# Find this line (around line 12):
#   channel_id: "REPLACE_WITH_CHANNEL_ID"
# Replace with actual ID:
#   channel_id: "C01234ABCD"  # Your actual channel ID
```

### Step 2: Create Secret for OpenAI API Key

**Option A: Via kubectl (for testing/dev)**

```bash
# Create the secret directly
# The secret is managed by secretsync from the vault item.
# Verify it exists:
oc get secret cluster-secrets-chaibot-openai-key -n ci
```

**Option B: Via ci-secret-bootstrap (for production)**

```bash
# 1. Store the key in Vault (ask DPTP team for path)

# 2. Add to core-services/ci-secret-bootstrap/_config.yaml:
- from:
    openai-api-key:
      path: <vault-path-to-key>
  to:
    - cluster: app.ci
      namespace: ci
      name: ci-chat-bot-chaibot-secrets

# 3. Submit PR to openshift/release
# 4. After merge, ci-secret-bootstrap will sync the secret
```

### Step 3: Apply ConfigMap

```bash
# Apply the Chaibot configuration ConfigMap
oc apply -f clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml

# Verify
oc get configmap ci-chat-bot-triage-config -n ci -o yaml
```

### Step 4: Apply Prometheus Alerts

```bash
# Extract and apply just the PrometheusRule from the patch file
cat > /tmp/chaibot-alerts.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: chaibot-alerts
  namespace: ci
spec:
  groups:
    - name: chaibot
      interval: 30s
      rules:
        - alert: ChaibotHighErrorRate
          expr: |
            rate(chaibot_api_errors_total[5m]) > 0.1
          for: 10m
          labels:
            severity: warning
            team: test-platform
          annotations:
            summary: "Chaibot experiencing high error rate"
            description: "Chaibot has {{ $value }} errors per second over the last 5 minutes."

        - alert: ChaibotAnalysisTimeout
          expr: |
            histogram_quantile(0.95, rate(chaibot_analysis_duration_seconds_bucket[5m])) > 120
          for: 15m
          labels:
            severity: warning
            team: test-platform
          annotations:
            summary: "Chaibot analysis taking too long"
            description: "95th percentile analysis duration is {{ $value }}s, exceeding 120s timeout."

        - alert: ChaibotDown
          expr: |
            up{job="ci-chat-bot"} == 0
          for: 5m
          labels:
            severity: critical
            team: test-platform
          annotations:
            summary: "Chaibot service is down"
            description: "ci-chat-bot service (including Chaibot) has been down for 5 minutes."
EOF

oc apply -f /tmp/chaibot-alerts.yaml

# Verify
oc get prometheusrule chaibot-alerts -n ci
```

### Step 5: Deploy Updated ci-chat-bot

```bash
# The deployment YAML has already been updated with:
# - Chaibot volumes (triage-config, chaibot-secrets)
# - Volume mounts in bot container
# - Environment variables (CHAIBOT_ENABLED, OPENAI_API_KEY)
# - Command args (--enable-triage, --triage-config-path)

# Review the changes
git diff clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml

# Apply the updated deployment
oc apply -f clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml

# Watch the rollout (this will restart the pod)
oc rollout status deployment/ci-chat-bot -n ci --timeout=5m
```

### Step 6: Verify Deployment

```bash
# Check pod status
oc get pods -n ci -l app=ci-chat-bot

# Check logs for Chaibot initialization
oc logs -n ci deployment/ci-chat-bot -c bot --tail=100 | grep -i chaibot

# Should see something like:
# INFO: Chaibot triage enabled
# INFO: Monitoring channels: [opp-discussion]
# INFO: AI provider: openai (model: gpt-4)
```

### Step 7: Test Functionality

**Method 1: Post a test message in Slack**

In `#opp-discussion`:
```
Test failure: https://prow.ci.openshift.org/view/gs/origin-ci-test/pr-logs/pull/12345/...
```

Wait 30-60 seconds for Chaibot to respond in thread.

**Method 2: Check metrics**

```bash
# Port-forward to access metrics
oc port-forward -n ci deployment/ci-chat-bot 9090:9090 &

# Query metrics
curl http://localhost:9090/metrics | grep chaibot

# Look for:
# chaibot_messages_processed_total
# chaibot_failures_detected_total
# chaibot_analyses_completed_total
```

**Method 3: Monitor logs**

```bash
# Follow logs for Chaibot activity
oc logs -n ci deployment/ci-chat-bot -c bot -f | grep -i "chaibot\|triage"
```

## Troubleshooting

### Pod won't start

```bash
# Check events
oc describe pod -n ci -l app=ci-chat-bot

# Common issues:
# - Missing secret: ci-chat-bot-chaibot-secrets
# - Missing configmap: ci-chat-bot-triage-config
# - Invalid YAML syntax in configmap
```

### Chaibot not responding in Slack

```bash
# 1. Check if feature is enabled
oc exec -n ci deployment/ci-chat-bot -c bot -- env | grep CHAIBOT_ENABLED
# Should output: CHAIBOT_ENABLED=true

# 2. Check config is mounted
oc exec -n ci deployment/ci-chat-bot -c bot -- cat /etc/triage-config/triage-config.yaml

# 3. Check for errors in logs
oc logs -n ci deployment/ci-chat-bot -c bot --tail=200 | grep -i error

# 4. Verify channel ID is correct
oc get configmap ci-chat-bot-triage-config -n ci -o jsonpath='{.data.triage-config\.yaml}' | grep channel_id
```

### OpenAI API errors

```bash
# Check if API key is set
oc exec -n ci deployment/ci-chat-bot -c bot -- env | grep OPENAI_API_KEY
# Should show: OPENAI_API_KEY=sk-...

# Check rate limits
curl http://localhost:9090/metrics | grep chaibot_api_errors_total

# Common issues:
# - Invalid API key
# - Rate limit exceeded
# - No credits remaining in OpenAI account
```

### Wrong Slack channel

```bash
# Update the channel ID in ConfigMap
oc edit configmap ci-chat-bot-triage-config -n ci

# Find the channel_id line and update it
# Save and exit

# Restart the deployment to pick up changes
oc rollout restart deployment/ci-chat-bot -n ci
```

## Important Notes

### 1. Code Implementation Required

⚠️ **CRITICAL**: This deployment assumes the ci-chat-bot binary in the container already has Chaibot support. The code needs to be implemented in the `openshift/ci-tools` repository (`cmd/ci-chat-bot`).

If the code doesn't exist yet, the bot will start but ignore the `--enable-triage` flag and related configs.

To check if Chaibot code exists:
```bash
# Check the container image source
# Look in https://github.com/openshift/ci-tools/tree/master/cmd/ci-chat-bot
# Search for "triage" or "chaibot" functionality
```

### 2. Slack App Permissions

Ensure the ci-chat-bot Slack app has these OAuth scopes:
- `channels:history` - Read channel messages
- `channels:read` - View channel info
- `chat:write` - Post messages
- `files:read` - Access logs
- `reactions:write` - Add reactions

And subscribed to these events:
- `message.channels`
- `app_mention`

Check/update at: https://api.slack.com/apps (find ci-chat-bot app)

### 3. Cost Management

Monitor OpenAI API usage to control costs:

```bash
# Check number of analyses
curl http://localhost:9090/metrics | grep chaibot_analyses_completed_total

# At $0.03 per analysis (GPT-4):
# 100/day = $3/day = ~$90/month
# 
# To reduce costs:
# - Use GPT-3.5-turbo (~$0.003/analysis)
# - Adjust rate_limiting in config
# - Increase cooldown_seconds
```

Edit ConfigMap to switch models:
```yaml
analysis:
  model: "gpt-3.5-turbo"  # Change from "gpt-4"
```

### 4. Production Readiness Checklist

Before enabling in production:

- [ ] OpenAI API key stored in Vault (not hardcoded)
- [ ] Correct Slack channel ID configured
- [ ] Slack app permissions verified
- [ ] PrometheusRules deployed and alerting configured
- [ ] Grafana dashboard created
- [ ] Rate limits tuned appropriately
- [ ] Cost monitoring set up
- [ ] Team trained on Chaibot usage
- [ ] Runbook created for oncall
- [ ] Code implementation verified in ci-tools

## Rollback

If you need to disable Chaibot:

```bash
# Method 1: Disable via environment variable
oc set env deployment/ci-chat-bot CHAIBOT_ENABLED=false -n ci

# Method 2: Remove volumes and mounts
# Revert clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml to previous version
git checkout HEAD~1 -- clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml
oc apply -f clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml

# Method 3: Delete ConfigMap (feature will fail gracefully)
oc delete configmap ci-chat-bot-triage-config -n ci
```

## Next Steps

After successful deployment:

1. **Monitor initial performance**
   - Watch metrics and logs for 24-48 hours
   - Collect feedback from #opp-discussion users

2. **Tune configuration**
   - Adjust confidence thresholds based on accuracy
   - Add/remove failure patterns
   - Optimize AI prompts

3. **Expand coverage**
   - Add more monitored channels
   - Create team-specific configurations
   - Integrate with retester for auto-retry

4. **Documentation**
   - Update team wiki with usage examples
   - Create runbook for DPTP oncall
   - Add to CI documentation site

## Support

- **Documentation**: `docs/chaibot-test-failure-triage.md`
- **Quick Reference**: `core-services/ci-chat-bot/CHAIBOT.md`
- **Questions**: #forum-ocp-testplatform
- **ci-chat-bot team**: #forum-ocp-crt
- **Issues**: https://github.com/openshift/ci-tools/issues
