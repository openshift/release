---
description: Add hypershift debug ref and rehearse changes
args: "config_name release"
allowed-tools: Read, Edit, Bash, Grep, Glob
---

# Rehearse Debug Cluster - Automated

Execute all steps in one continuous flow without pausing. Add wait reference to test config and trigger rehearsal.

**Arguments**: config_name={{config_name}} release={{release}}

## Workflow

Run all steps as parallel tool calls where possible, sequentially where dependencies exist:

1. **Setup**: `git checkout master && git pull && git checkout -b debug-cluster-{{config_name}}`

2. **Find file**: Search `ci-operator/config/openshift/openshift-tests-private/` for file matching:
   - Contains: `{{config_name}}`
   - Filename contains: `{{release}}`
   - Filename does NOT contain: `upgrade`

3. **Edit file**: Add `    - ref: wait` after the `-chain` line in the `{{config_name}}` test block

4. **Commit & PR**:
   ```
   git add . && git commit -m "debug-cluster-{{config_name}}" && gh auth setup-git && git push -u origin debug-cluster-{{config_name}}
   gh pr create --repo openshift/release --title "debug-cluster-{{config_name}}" --body "Add wait ref to {{config_name}}"
   ```

5. **Monitor & trigger**: Extract PR number, poll for REHEARSALNOTIFIER comment, extract test name from table, post `/pj-rehearse <test-name>`

## Output

Report only:
- PR URL
- Test name
- Rehearsal trigger confirmation
