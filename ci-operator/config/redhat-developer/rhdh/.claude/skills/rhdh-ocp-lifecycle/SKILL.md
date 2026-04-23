---
name: rhdh-ocp-lifecycle
description: >-
  Check which OCP versions are supported by active RHDH releases and which are
  end-of-life, using the Red Hat Product Life Cycles API for both RHDH and OCP
  lifecycle data including EUS phases. Supports OCP 4.x and future 5.x+
---
# Check RHDH and OCP Lifecycle Status

Query the Red Hat Product Life Cycles API to determine:
- Which RHDH releases are currently supported (Full Support or Maintenance)
- Which OCP versions each active RHDH release supports
- Which OCP versions are still supported upstream (including EUS phases)

## When to Use

Use this skill when you need to check version support status before:
- Adding or removing RHDH cluster pools
- Adding or removing OCP-versioned CI test entries
- Planning RHDH release branch OCP coverage
- Running the `rhdh-ocp-coverage` analysis skill

## Prerequisites

- `curl` and `jq` must be available
- Internet connectivity to reach `https://access.redhat.com`

## Usage

Run the bundled script from the repository root:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-ocp-lifecycle.sh"
```

### Check a specific OCP version

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-ocp-lifecycle.sh" --version 4.16
```

### Check a specific RHDH version

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-ocp-lifecycle.sh" --rhdh-version 1.9
```

### Show only RHDH lifecycle (skip OCP table)

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/check-ocp-lifecycle.sh" --rhdh-only
```

## Output

### RHDH Lifecycle Table

Shows each RHDH release with:

| Column | Description |
|--------|-------------|
| VERSION | RHDH release version (e.g., `1.9`) |
| SUPPORTED | `yes` or `no` |
| TYPE | `Full Support`, `Maintenance Support`, or `End of life` |
| GA_DATE | General Availability date |
| FULL_SUPPORT_END | End of Full Support phase |
| MAINTENANCE_END | End of Maintenance Support phase |
| SUPPORTED_OCP_VERSIONS | OCP versions this RHDH release officially supports |

After the table, a summary shows:
- The union of OCP versions supported across all active RHDH releases
- Per-release OCP support breakdown

### OCP Lifecycle Table

Shows each OCP version (4.x and future 5.x+) with two support indicators:

| Column | Description |
|--------|-------------|
| VERSION | OCP minor version (e.g., `4.16`) |
| OCP_SUPP | `yes` if OCP version has upstream support (any phase) |
| RHDH_SUPP | `yes` if any active RHDH release supports this OCP version |
| PHASE | Current OCP lifecycle phase |
| GA_DATE | OCP General Availability date |
| END_DATE | Latest end-of-support date across all OCP phases |

The **RHDH_SUPP** column is the key indicator for CI coverage decisions. An OCP version should only have cluster pools and test entries if `RHDH_SUPP=yes`.

### JSON Summary (stderr)

A JSON object is written to stderr with:
- `rhdh_supported_versions`: Array of active RHDH releases with their OCP compatibility
- `ocp_versions_supported_by_rhdh`: Deduplicated array of OCP versions supported by any active RHDH release

## Data Sources

- **RHDH lifecycle**: `https://access.redhat.com/product-life-cycles/api/v1/products?name=Red+Hat+Developer+Hub`
  - Provides `openshift_compatibility` field per RHDH version (the authoritative source for which OCP versions RHDH supports)
  - Provides lifecycle phase and dates per RHDH version
- **OCP lifecycle**: `https://access.redhat.com/product-life-cycles/api/v1/products?name=OpenShift+Container+Platform+4`
  - Provides lifecycle phase and dates per OCP version (Full, Maintenance, EUS Term 1/2)

## Key Concepts

- **RHDH-supported OCP versions** are the OCP versions listed in the `openshift_compatibility` field of active RHDH releases. This is the set that should have cluster pools and CI test entries.
- **OCP-supported versions** include all OCP versions still receiving updates (Full, Maintenance, or EUS). This is a broader set — not all OCP-supported versions are relevant for RHDH.
- An OCP version can be OCP-supported but not RHDH-supported (e.g., an older EUS version that RHDH has dropped).
