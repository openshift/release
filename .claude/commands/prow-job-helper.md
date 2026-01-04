---
name: prow-job-helper
description: Help trigger Prow jobs via REST API, query job status, and understand job execution
parameters:
  - name: action
    description: Action to perform - "trigger", "status", "query", "help", or "list" (default: help)
    required: false
  - name: job_name
    description: Name of the Prow job (e.g., "periodic-ci-openshift-origin-master-e2e-aws")
    required: false
  - name: execution_id
    description: Execution ID from a triggered job (for status queries)
    required: false
---
You are helping users interact with Prow jobs via the REST API (Gangway) in OpenShift CI.

## Context

OpenShift CI provides a REST API (Gangway) for triggering and querying Prow jobs:
- **Endpoint**: `https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions`
- **Authentication**: OpenShift SSO token from `app.ci` cluster
- **Rate Limits**: API has rate limits, username recorded in annotations
- **Use Cases**: Primarily for periodic jobs, postsubmit jobs, and job status queries

⚠️ **Warning**: This API is for advanced users. Typical users should use `/test` and `/retest` Prow commands via GitHub.

## Your Task

Based on the user's request: action="{{action}}"{{#if job_name}}, job="{{job_name}}"{{/if}}{{#if execution_id}}, execution_id="{{execution_id}}"{{/if}}

1. **Provide guidance** based on the action:

   **trigger** - Help trigger a Prow job:
   - Explain job execution types (periodic=1, postsubmit=2, presubmit=3)
   - Provide curl command templates
   - Explain required parameters
   - Show how to override environment variables
   - Explain payload overrides

   **status** - Query job execution status:
   - Show how to query by execution ID
   - Explain response format
   - Interpret job status values

   **query** - General job queries:
   - Finding job names
   - Understanding job types
   - Job configuration lookup

   **list** - List available jobs:
   - How to find periodic jobs
   - How to find postsubmit jobs
   - Job naming conventions

   **help** - General help:
   - API overview
   - Common use cases
   - Authentication setup
   - Documentation references

2. **Authentication**: `oc whoami -t` (from app.ci cluster)

3. **Job Types**: `1`=Periodic, `2`=Postsubmit, `3`=Presubmit (not recommended)

4. **Key Commands**:
   ```bash
   # Trigger periodic
   curl -X POST -H "Authorization: Bearer $(oc whoami -t)" \
     -d '{"job_name": "periodic-ci-...", "job_execution_type": "1"}' \
     https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
   
   # Query status
   curl -X GET -H "Authorization: Bearer $(oc whoami -t)" \
     https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/{id}
   ```

5. **Env Overrides**: Prefix with `MULTISTAGE_PARAM_OVERRIDE_` in `pod_spec_options.envs`

6. **Important**:
   - ⚠️ Rate limits apply, username tracked
   - ⚠️ Presubmits: Use `/test` and `/retest` via GitHub
   - ✅ Periodic jobs are primary use case

## Example Output

```
**Trigger Job**:
```bash
curl -X POST -H "Authorization: Bearer $(oc whoami -t)" \
  -d '{"job_name": "periodic-ci-...", "job_execution_type": "1"}' \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions
```

**Query Status**:
```bash
curl -X GET -H "Authorization: Bearer $(oc whoami -t)" \
  https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/{id}
```
```

Now help the user with: "{{action}}"{{#if job_name}} for job "{{job_name}}"{{/if}}{{#if execution_id}} execution "{{execution_id}}"{{/if}}

