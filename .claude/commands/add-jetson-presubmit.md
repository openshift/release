---
description: Add optional presubmit test for qe-rhel-jetson that can be triggered with /test
args: "[test-name] [test-suites]"
allowed-tools: Read, Edit, Write, Bash, AskUserQuestion
---

# Add qe-rhel-jetson Presubmit Test

Adds a manually-triggerable presubmit test to qe-rhel-jetson so you can run `/test <name>` on PRs.

## Usage

```bash
/add-jetson-presubmit e2e-quick "tests_suites/sanity tests_suites/cuda"
/add-jetson-presubmit e2e-sanity "tests_suites/sanity"
```

## What This Does

Creates an **optional** presubmit test configuration that:
- Does NOT block PR merges (`optional: true`)
- Only runs when manually triggered via `/test <name>` (`always_run: false`)
- Can optionally run automatically when test files change (`run_if_changed`)

## Steps

1. **Read current config** - Check existing tests
2. **Ask configuration questions**:
   - Should this run automatically when test files change? (or manual-only)
   - Which bootc image base? (rhel-98-bootc or rhel-9-bootc)
   - Enable parallel execution? (default: yes, 2 workers)
3. **Add test configuration** to rhel-9.8.yaml
4. **Run make update** to generate Prow jobs
5. **Commit changes**

## Example Output

After running, you'll be able to:
```bash
# In qe-rhel-jetson PRs:
/test e2e-quick          # Triggers the new presubmit test
/test images             # Still works
/test lint               # Still works
```

## Implementation

```yaml
# Adds to ci-operator/config/rh-ecosystem-edge/qe-rhel-jetson/rh-ecosystem-edge-qe-rhel-jetson-rhel-9.8.yaml
tests:
- as: <test-name>
  optional: true
  always_run: false
  run_if_changed: "^tests_suites/"  # Optional
  capabilities:
  - intranet
  steps:
    env:
      BOOTC_IMAGE_BASE: quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc
      JETSON_PYTEST_WORKERS: "2"
      JUMPHOST: ""
      RUN_SC7_WRAPPER: "0"
      TEST_SUITE: <specified-test-suites>
    pre:
    - ref: qe-rhel-jetson-get-latest-bootc-tag
    - ref: qe-rhel-jetson-bootc-switch
    workflow: qe-rhel-jetson-e2e
```

## Notes

- **Hardware required**: These tests still need physical Jetson hardware (Beaker)
- **Runtime**: Depends on test suite size (sanity ~5min, full ~30-60min)
- **Cost**: Each run uses Beaker reservation time
- **Recommendation**: Create smaller/faster test subsets for presubmits

## Execution

When you invoke this skill:

1. Parse arguments for test name and test suites
2. Read the current rhel-9.8.yaml config
3. Ask user for configuration preferences
4. Generate the new test configuration
5. Insert it into the tests array (after periodic tests)
6. Run `make update` to regenerate Prow jobs
7. Show the generated job name and `/test` command
8. Ask if user wants to commit the changes

---

## Skill Logic

Read the qe-rhel-jetson rhel-9.8 config, ask the user configuration questions, add the test entry, run make update, and optionally commit.

Ask these questions:
1. **Run automatically on test changes?** 
   - Yes: Add `run_if_changed: "^tests_suites/"`
   - No: Manual-only (`/test` command)

2. **Which bootc image?**
   - rhel-98-bootc (default, for RHEL 9.8)
   - rhel-9-bootc (for RHEL 9 base)

3. **Enable parallel execution?**
   - Yes (default): JETSON_PYTEST_WORKERS=2
   - No: JETSON_PYTEST_WORKERS=0

4. **Disable SC7 tests?**
   - Yes (default): RUN_SC7_WRAPPER=0
   - No: RUN_SC7_WRAPPER=1

Generate test config, insert after last test in the array, run make update, show results, offer to commit.
