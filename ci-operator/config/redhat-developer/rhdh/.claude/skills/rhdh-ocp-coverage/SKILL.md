---
name: rhdh-ocp-coverage
description: >-
  Analyze RHDH OCP version coverage by cross-referencing cluster pools and CI
  test configs against both RHDH and OCP lifecycle APIs to find gaps, stale
  configurations, and compatibility mismatches
---
# RHDH OCP Coverage Analysis

Cross-reference RHDH cluster pools, CI test configurations, RHDH lifecycle data, and OCP lifecycle data to identify coverage gaps and stale configurations.

## When to Use

Use this skill when you need to:
- Check if RHDH CI coverage matches the current RHDH-supported OCP versions
- Find OCP versions that RHDH no longer supports but still have active pools or test entries
- Find RHDH-supported OCP versions missing cluster pools or test entries
- Plan OCP version additions or removals for a new RHDH release

## Prerequisites

- `curl`, `jq`, and `yq` (v4+) must be available
- Internet connectivity to reach `https://access.redhat.com`
- Working directory must be the root of the `openshift/release` repository

## Usage

Run the bundled analysis script from the repository root:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/analyze-coverage.sh"
```

## Two Dimensions of Support

The analysis checks two independent dimensions for each OCP version:

| Dimension | Source | Meaning |
|-----------|--------|---------|
| **OCP supported** | OCP lifecycle API | The OCP version itself is still receiving updates (Full, Maintenance, or EUS) |
| **RHDH supported** | RHDH lifecycle API (`openshift_compatibility` field) | RHDH officially supports running on this OCP version |

An OCP version must satisfy **both** to warrant a cluster pool and test entry:
- An OCP-EOL version should always be removed (regardless of RHDH compatibility)
- An OCP-supported but non-RHDH-supported version should be reviewed (e.g., old EUS versions RHDH has dropped)

## How `main` Branch Is Handled

The `main` branch targets the **next unreleased RHDH version**. Since it's unreleased, it doesn't appear in the RHDH lifecycle API. The script estimates its OCP support as:

> Latest active RHDH release's OCP versions **+** any newer OCP versions that have reached GA

For example, if RHDH 1.9 supports OCP 4.16-4.21 and OCP 4.22 just went GA, then `main` is estimated to support 4.16-4.22.

## Output Sections

### 1. Current State

- Cluster pool versions with sizing
- Test entry versions per product branch
- RHDH lifecycle with per-release OCP compatibility
- OCP lifecycle with supported/EOL versions

### 2. OCP Version Matrix

A combined view showing each relevant OCP version with:

| Column | Description |
|--------|-------------|
| OCP | Version number |
| OCP_SUPP | Is OCP itself still supported? |
| RHDH_SUPP | Does any active RHDH release support this OCP? |
| OCP_PHASE | Current OCP lifecycle phase |
| RHDH_RELEASES | Which RHDH releases support this OCP |

### 3. Analysis Results

Actions are categorized by severity:

- **REMOVE** — Definitive: OCP version is end-of-life, resources should be deleted
- **REVIEW** — Needs judgment: OCP is supported but RHDH compatibility doesn't match, or vice versa
- **ADD** — Missing: RHDH-supported OCP version lacks a pool or test entry

Specific checks:
- Pools for OCP-EOL versions (REMOVE)
- Pools for OCP versions not in any RHDH release's compatibility list (REVIEW)
- Test entries mismatched with the branch's RHDH compatibility (REMOVE/REVIEW)
- RHDH-supported OCP versions missing pools (ADD)
- RHDH-supported OCP versions missing test entries per branch (ADD)

### 4. Summary

Counts per action category plus the per-branch OCP support mapping.

## Workflow

After running the analysis:

1. **Handle REMOVE items first** — delete pools/tests for OCP-EOL versions
2. **Review REVIEW items** — decide based on context whether they need action
3. **Handle ADD items** — use `rhdh-ocp-pool` and `rhdh-ocp-tests` skills
4. **Run `make update`** after all changes
5. **Commit both config and generated files** together

## Data Sources

- **RHDH lifecycle**: `https://access.redhat.com/product-life-cycles/api/v1/products?name=Red+Hat+Developer+Hub`
- **OCP lifecycle**: `https://access.redhat.com/product-life-cycles/api/v1/products?name=OpenShift+Container+Platform+4`
- **RHDH support policy**: `https://access.redhat.com/support/policy/updates/developerhub`

## Related Skills

- `rhdh-ocp-lifecycle` — Check RHDH and OCP version support status
- `rhdh-ocp-pool` — List and generate OCP cluster pool configurations
- `rhdh-ocp-tests` — List, generate, add, and remove OCP test entries
