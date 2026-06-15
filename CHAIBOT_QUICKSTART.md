# Chaibot Quick Start Guide

## What is Chaibot?

An AI-powered Slack workflow that automatically triages test failures in #opp-discussion and posts analysis in threads.

## Files Created

```
core-services/ci-chat-bot/
├── triage-config.yaml          # Main config (source of truth)
└── CHAIBOT.md                  # Quick reference

clusters/app.ci/ci-chat-bot/
├── chaibot-configmap.yaml      # Kubernetes ConfigMap
└── chaibot-deployment-patch.yaml  # Deployment updates + alerts

core-services/ci-secret-bootstrap/
└── chaibot-secret-config.yaml  # Secret management

docs/
└── chaibot-test-failure-triage.md  # Full documentation
```

## How to Deploy

### Step 1: Get Credentials

```bash
# 1. Get OpenAI API key from https://platform.openai.com/api-keys

# 2. Get Slack channel ID:
#    - Right-click #opp-discussion in Slack
#    - View channel details
#    - Copy Channel ID (looks like C01234ABCD)

# 3. Update clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml
#    Replace REPLACE_WITH_CHANNEL_ID with actual ID
```

### Step 2: Configure Secrets

```bash
# Add to core-services/ci-secret-bootstrap/_config.yaml:
# (Follow pattern in chaibot-secret-config.yaml)

# Store OpenAI key in Vault
# Reference: https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/
```

### Step 3: Update ci-chat-bot Deployment

Edit `clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml` and add:

```yaml
# Add to spec.template.spec.volumes:
- name: triage-config
  configMap:
    name: ci-chat-bot-triage-config
- name: chaibot-secrets
  secret:
    secretName: cluster-secrets-chaibot-openai-key

# Add to spec.template.spec.containers[name=bot].volumeMounts:
- name: triage-config
  mountPath: /etc/triage-config
  readOnly: true
- name: chaibot-secrets
  mountPath: /etc/chaibot-secrets
  readOnly: true

# Add to spec.template.spec.containers[name=bot].env:
- name: CHAIBOT_ENABLED
  value: "true"
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: ci-chat-bot-chaibot-secrets
      key: openai-api-key

# Add to spec.template.spec.containers[name=bot].args:
--enable-triage=true \
--triage-config-path=/etc/triage-config/triage-config.yaml \
```

### Step 4: Deploy

```bash
# From openshift/release repo root:
make update

# Apply ConfigMap
oc apply -f clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml

# Apply updated deployment (after editing)
oc apply -f clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml

# Watch rollout
oc rollout status deployment/ci-chat-bot -n ci
```

### Step 5: Test

```
# In Slack #opp-discussion:
Post a message with a Prow job URL:

"This job failed: https://prow.ci.openshift.org/view/gs/origin-ci-test/..."

# Chaibot should respond in thread within 30-60 seconds
```

## Example Output

```
Chaibot [BOT]: :cloud: Test Failure Analysis

Job: pull-ci-openshift-installer-master-e2e-aws
Status: Failed after 2h 15m
Root Cause: Infrastructure - AWS EC2 Capacity (85% confidence)

Analysis:
Cluster provisioning failed due to AWS InsufficientInstanceCapacity error.

Evidence:
Error: creating EC2 Instance: InsufficientInstanceCapacity (us-east-1c)

Historical:
8 similar failures in last 24h (transient AWS issue)

Recommendations:
1. Retest - likely to succeed on retry
2. Check AWS Service Health Dashboard

Classification: Transient Infrastructure Issue
```

## Configuration

Edit `core-services/ci-chat-bot/triage-config.yaml`:

```yaml
# Add channels
monitored_channels:
  - name: "opp-discussion"
    channel_id: "C01234567"

# Adjust AI settings
analysis:
  ai_provider: "openai"
  model: "gpt-4"  # or "gpt-3.5-turbo" for lower cost

# Rate limiting
rate_limiting:
  max_analyses_per_hour: 100
```

## Monitoring

```bash
# Check logs
oc logs -n ci deployment/ci-chat-bot -c bot | grep chaibot

# View metrics
curl http://ci-chat-bot.ci.svc:9090/metrics | grep chaibot

# Grafana dashboard
https://grafana.ci.openshift.org/d/chaibot/
```

## Troubleshooting

**Not responding?**
```bash
oc get pods -n ci -l app=ci-chat-bot
oc logs -n ci -l app=ci-chat-bot -c bot --tail=50
```

**Wrong channel ID?**
```bash
oc get configmap ci-chat-bot-triage-config -n ci -o yaml
# Update and reapply
```

**API errors?**
```bash
# Check secret exists
oc get secret ci-chat-bot-chaibot-secrets -n ci

# View metrics for errors
curl http://ci-chat-bot.ci.svc:9090/metrics | grep chaibot_api_errors
```

## Cost

- GPT-4: ~$0.03/analysis (~$90/month at 100 failures/day)
- GPT-3.5-turbo: ~$0.003/analysis (~$9/month at 100 failures/day)

Rate limiting prevents cost overruns.

## Support

- **Questions**: #forum-ocp-testplatform
- **ci-chat-bot team**: #forum-ocp-crt
- **Full docs**: docs/chaibot-test-failure-triage.md
- **Issues**: https://github.com/openshift/ci-tools/issues

## Important Note

⚠️ This configuration requires **code implementation** in the ci-tools repo (openshift/ci-tools cmd/ci-chat-bot) to function. The configs are ready, but the bot logic needs development to:

1. Parse triage-config.yaml
2. Listen to Slack events
3. Fetch job logs from GCS
4. Call OpenAI API
5. Format and post responses

See `docs/chaibot-test-failure-triage.md` for implementation details.
