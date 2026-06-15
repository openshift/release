# Chaibot Quick Start Guide (Ship-Help MCP Version)

## What is Chaibot?

An AI-powered Slack workflow that automatically triages test failures in #opp-discussion using **Chai Bot** (ship-help MCP) and posts analysis in threads.

**Key Difference from Original:** Uses Chai Bot instead of OpenAI - $0/month cost, richer analysis.

## Files Created

```
core-services/ci-chat-bot/
├── triage-config.yaml          # Main config (ship-help MCP settings)
└── CHAIBOT.md                  # Quick reference

clusters/app.ci/ci-chat-bot/
├── chaibot-configmap.yaml      # Kubernetes ConfigMap
└── ci-chat-bot.yaml            # Updated deployment

core-services/ci-secret-bootstrap/
└── chaibot-secret-config.yaml  # Ship-help token management

openshift/ci-tools/
├── pkg/chaibot/analyzer.go     # Ship-help MCP client
└── cmd/ci-chat-bot/main.go     # Integration code

docs/
└── chaibot-test-failure-triage.md  # Full documentation
```

## How to Deploy

### Step 1: Get Ship-Help MCP Token

**Option A: Use existing token (for testing)**
```bash
# Extract from your Claude config
grep "Authorization" ~/.claude/.claude.json | grep ship-help

# Copy the token (everything after "Bearer ")
```

**Option B: Request team token (for production)**
```bash
# Contact #ship-users in Slack
# Ask for a team-specific ship-help MCP token for ci-chat-bot
```

### Step 2: Store Token in Vault

```bash
# Use DPTP process to store token in Vault
# Path: selfservice/cspi-qe/ship-help-mcp-token
# Field: token
# Value: <your-token>

# Reference: https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/
```

### Step 3: Deploy Configuration

```bash
# From openshift/release repo root:

# Apply ConfigMap
oc apply -f clusters/app.ci/ci-chat-bot/chaibot-configmap.yaml

# Verify secret exists (synced from Vault)
oc get secret cluster-secrets-chaibot-ship-help -n ci

# Apply updated deployment
oc apply -f clusters/app.ci/ci-chat-bot/ci-chat-bot.yaml

# Watch rollout
oc rollout status deployment/ci-chat-bot -n ci
```

### Step 4: Verify Deployment

```bash
# Check pod status
oc get pods -n ci -l app=ci-chat-bot

# Check logs for Chaibot initialization
oc logs -n ci deployment/ci-chat-bot -c bot --tail=100 | grep -i chaibot

# Should see:
# INFO: Chaibot triage enabled
# INFO: Monitoring channels: [opp-discussion]
# INFO: AI provider: ship-help-mcp
```

### Step 5: Test

Post in #opp-discussion:
```
This job failed: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816
```

Chaibot should respond in thread within 30-60 seconds with analysis.

## Example Output

```
Chaibot [BOT]: ✅ Failure Analysis Complete

Job: periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws
Status: ❌ FAILED (5h55m)

Root Cause: acm-fetch-managed-clusters step failure
Category: Infrastructure - Pod failure (85% confidence)

Analysis:
Managed cluster provisioned during acm-tests-clc-create did not register 
properly, causing managedClusters.json to be empty/null.

Auto-Filed Bugs:
• ACM-35382 - Pod failure in acm-fetch-managed-clusters
• LPINTEROP-6873 - Test failure in acm-tests-clc-create

Historical Pattern:
10 similar failures since July 2025 - systemic issue

Recommendations:
1. Investigate managed cluster lifecycle
2. Contact ACM Cluster Lifecycle team
3. Add health checks before data fetch

Analysis completed in 42.3s • Powered by Chai Bot
```

## Configuration

Edit `core-services/ci-chat-bot/triage-config.yaml`:

```yaml
# Add channels
monitored_channels:
  - name: "opp-discussion"
    channel_id: "C04TMLC6DRV"
  - name: "forum-testplatform"
    channel_id: "CHANNEL_ID_HERE"

# Adjust prompt template (uses proven /analyze-failure format)
analysis:
  prompt_template: |
    Analyze this failed Prow CI job: {job_url}
    ...

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

# Available metrics:
# - chaibot_analyses_completed_total
# - chaibot_analysis_duration_seconds
# - chaibot_mcp_errors_total
```

## Troubleshooting

**Not responding?**
```bash
# Check if enabled
oc exec -n ci deployment/ci-chat-bot -c bot -- env | grep CHAIBOT_ENABLED
# Should output: CHAIBOT_ENABLED=true

# Check token
oc get secret cluster-secrets-chaibot-ship-help -n ci

# Check config
oc get configmap ci-chat-bot-triage-config -n ci -o yaml
```

**Analysis timeout?**
- Ship-help MCP is slower than expected (normally <60s)
- Check ship-help service status in #ship-users
- Increase timeout in config if needed

**Wrong channel?**
```bash
# Update channel ID in ConfigMap
oc edit configmap ci-chat-bot-triage-config -n ci

# Restart deployment
oc rollout restart deployment/ci-chat-bot -n ci
```

## Cost

- **Ship-help MCP**: $0/month (shared service)
- **No OpenAI costs**: Saves ~$90/month vs original PR
- **Infrastructure**: Negligible (existing ci-chat-bot pods)

## Comparison to Original PR

| Feature | Original (OpenAI) | This PR (Ship-Help) |
|---------|------------------|---------------------|
| **Cost** | ~$90/month | $0/month |
| **Data Sources** | 3 | 9+ |
| **Privacy** | External vendor | Internal only |
| **Analysis Quality** | Generic GPT-4 | Specialized Chai Bot |
| **Proven** | New | Yes (/analyze-failure) |

## Support

- **Chaibot questions**: #forum-ocp-testplatform
- **Ship-help issues**: #ship-users
- **ci-chat-bot team**: #forum-ocp-crt
- **Full docs**: docs/chaibot-test-failure-triage.md

## Important Note

⚠️ This implementation requires code in openshift/ci-tools (pkg/chaibot, cmd/ci-chat-bot).  
The config is ready, but the bot logic needs the Go code provided in this PR.

See `analyzer.go` and `main-integration.go` for implementation details.
