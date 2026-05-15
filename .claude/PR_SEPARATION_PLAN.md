# PR Separation Plan

After the current debugging PR is complete and validated, create two separate PRs:

## PR 1: Trustee Operator Installation Fixes (Current Work)

**Purpose**: Fix trustee operator installation for sandboxed-containers-operator CoCo tests

**Branch**: `260512` (current)

**Files to include**:
- `ci-operator/config/openshift/sandboxed-containers-operator/openshift-sandboxed-containers-operator-devel__downstream-candidate.yaml`
  - Network access fix: `restrict_network_access: false` for CoCo tests
- `ci-operator/step-registry/sandboxed-containers-operator/install-trustee-operator/sandboxed-containers-operator-install-trustee-operator-ref.yaml`
  - Base image fix: `from: tools` (was `from: cli`)

**Files to EXCLUDE** (move to PR 2):
- `.claude/commands/pj-rehearse-debug.md`
- `.claude/commands/README.md` (only the pj-rehearse-debug section)

**Title**: `Fix trustee operator installation for CoCo tests`

**Labels**: Remove `do-not-merge/hold` after validation

---

## PR 2: Add /pj-rehearse-debug Skill (New PR)

**Purpose**: Add reusable debugging skill for CI job failures

**Branch**: Create new branch from `main` (e.g., `add-pj-rehearse-debug-skill`)

**Files to include**:
- `.claude/commands/pj-rehearse-debug.md` (the skill documentation)
- `.claude/commands/README.md` (documentation section for the skill)
- `.claude/scripts/monitor-rehearsal.sh` (standardized monitoring script)

**Files to EXCLUDE**:
- No sandboxed-containers-operator specific changes
- This is a pure skill addition

**Title**: `Add /pj-rehearse-debug skill for iterative CI job debugging`

**Description**:
```
Add a new slash command skill for debugging CI job failures using /pj-rehearse.

Features:
- Systematic workflow for identifying and fixing CI job issues
- Common debugging patterns (base images, network access, tool availability)
- Background monitoring script for long-running rehearsals
- Prow build log analysis techniques
- Iterative debugging examples

This skill is generic and works for any repository in openshift/release.
It was developed while debugging trustee operator installation issues
but is applicable to all CI job debugging scenarios.
```

**Labels**: `lgtm`, `approved` (standard skill PR)

---

## Steps to Separate

1. **Wait for current PR validation** 
   - Ensure rehearsal passes with both fixes applied
   - Verify trustee operator installs successfully

2. **Create skill-only branch**
   ```bash
   git checkout main
   git pull
   git checkout -b add-pj-rehearse-debug-skill
   ```

3. **Cherry-pick skill commits**
   ```bash
   # Get commit hashes from current branch
   git log 260512 --oneline | grep -E "pj-rehearse-debug|skill"
   
   # Cherry-pick skill-related commits
   git cherry-pick <commit-hash-1>
   git cherry-pick <commit-hash-2>
   ```

4. **Clean up current PR (260512)**
   ```bash
   git checkout 260512
   git rebase -i main
   # Remove skill commits from this branch
   # Keep only trustee operator fixes
   git push --force-with-lease
   ```

5. **Create skill PR**
   ```bash
   git checkout add-pj-rehearse-debug-skill
   git push -u origin add-pj-rehearse-debug-skill
   gh pr create --title "Add /pj-rehearse-debug skill..." --body "..."
   ```

---

## Rationale for Separation

**Benefits**:
- **Cleaner review**: Each PR has a single focused purpose
- **Independent merge**: Skill can merge without waiting for test validation
- **Reusability**: Skill PR can be referenced by other teams
- **History clarity**: Git history shows separate concerns
- **Risk isolation**: Trustee fixes are sandboxed-containers-operator specific; skill is universal

**Trustee PR**: Fixes specific test failures, requires rehearsal validation  
**Skill PR**: Documentation/tooling, can merge immediately after review
