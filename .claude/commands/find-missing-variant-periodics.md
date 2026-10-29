---
name: find-missing-variant-periodics
description: Find periodic configurations missing for a target release version
parameters:
  - name: from_release
    description: Source release version to search for existing configurations (e.g., "4.17", "4.18")
    required: true
  - name: to_release
    description: Target release version to check for missing configurations (e.g., "4.18", "4.19")
    required: true
  - name: path
    description: Optional directory path to search for periodic files (default is ci-operator/config/)
    required: false
---

You are helping users identify OpenShift periodic CI job configurations that exist for one release but are missing for another.

## Context

Periodic jobs are CI tests that run on a schedule (via cron) or after a specified interval since last execution rather than on pull requests. These are defined in files following the pattern: `*-release-{major.minor}__periodics.yaml` in the `ci-operator/config/` directory.

This is a **read-only analysis command** - it doesn't modify any files. Use it before `/migrate-variant-periodics` to understand the scope of work.

## Your Task

The user wants to find missing periodic configurations:
- **From release**: {{from_release}} (source - what exists)
- **To release**: {{to_release}} (target - check what's missing)
{{#if path}}- **Search path**: {{path}}{{else}}- **Search path**: ci-operator/config/ (default){{/if}}

## Implementation Steps

### 1. Normalize version numbers
- Parse and normalize from_release to `{major}.{minor}` format
- Parse and normalize to_release to `{major}.{minor}` format
- Strip any `release-` prefix or patch version numbers
- Handle formats: "4.17", "release-4.17", "4.17.0" → "4.17"
- Validate both version formats (must be X.Y)

### 2. Determine search path
- If path argument provided: use as-is (relative to repo root)
- If not provided: default to `ci-operator/config/`
- Verify path exists in repository

### 3. Find source periodic files
- Use Glob tool to search for pattern: `{search_path}/**/*-release-{from_version}__periodics.yaml`
- Example pattern: `ci-operator/config/**/*-release-4.17__periodics.yaml`
- **CRITICAL**: Automatically exclude ALL files under `ci-operator/config/openshift-priv/` from analysis
- Store list of found source files (excluding openshift-priv)
- If any openshift-priv files were excluded, note this in the output
- If no files found:
  - Inform user: "No periodic files found for release {from_version} in {search_path}"
  - Exit

### 4. Check for corresponding target files
For each source file found:
- Construct expected target filename by replacing:
  - `-release-{from_version}__periodics.yaml` with `-release-{to_version}__periodics.yaml`
- Check if target file exists (use Glob or attempt to Read)
- Track whether target exists or is missing

### 5. Build missing configurations report
Create two lists:
- **Missing**: Source files without corresponding target files
- **Exists**: Source files that already have target files

Calculate statistics:
- Total source files found
- Number missing target files
- Number with existing target files
- Percentage missing

### 6. Display results

Show summary statistics:
```
Periodic Configuration Analysis
===============================
Source Release: {from_version}
Target Release: {to_version}
Search Path: {search_path}

Results:
--------
Found {total} periodic configuration(s) for release {from_version}
Missing {missing_count} configuration(s) for release {to_version} ({percentage}%)
Existing {exists_count} configuration(s) for release {to_version} ({percentage}%)
```

List missing configurations:
```
Missing Configurations (need migration):
-----------------------------------------
1. ci-operator/config/openshift/etcd/openshift-etcd-release-{to_version}__periodics.yaml
2. ci-operator/config/openshift/kube-apiserver/openshift-kube-apiserver-release-{to_version}__periodics.yaml
...
```

Optionally list existing configurations (brief summary):
```
Existing Configurations (already migrated):
--------------------------------------------
{exists_count} configuration(s) already exist for release {to_version}
(Run with --show-existing to see the full list)
```

### 7. Provide next steps

If missing configurations found:
```
Next Steps:
-----------
To migrate missing configurations, run:
  /migrate-variant-periodics {from_version} {to_version}

To migrate specific repositories, run:
  /migrate-variant-periodics {from_version} {to_version} ci-operator/config/openshift/{repo}

Note: Review the missing list to determine which should actually be migrated.
Not all repositories may need periodic configs for all releases (EOL, not applicable, etc.)
```

If no missing configurations:
```
All periodic configurations for {from_version} have corresponding {to_version} configurations.
```

## Important Notes

- **CRITICAL - openshift-priv repositories**: This command automatically excludes all files under `ci-operator/config/openshift-priv/` from analysis. These are private repositories with special security considerations.
- **Discovery tool**: This is a read-only analysis - no files are modified
- **Use before migration**: Run this before `/migrate-variant-periodics` to understand scope
- **Version relationship**: Works in both directions (older→newer or newer→older)
- **Not all configs need migration**: Some repositories may intentionally not have periodic configs for certain releases
- **Complementary to migrate**: After identifying missing configs, use `/migrate-variant-periodics` to migrate

## Usage Examples

```
# Find all missing periodics from 4.17 to 4.18
/find-missing-variant-periodics 4.17 4.18

# Check specific repository
/find-missing-variant-periodics 4.18 4.19 ci-operator/config/openshift/cloud-credential-operator

# Find missing periodics for an organization
/find-missing-variant-periodics 4.19 4.20 ci-operator/config/openshift

```

## Example Output

```
Periodic Configuration Analysis
===============================
Source Release: 4.17
Target Release: 4.18
Search Path: ci-operator/config/openshift

Results:
--------
Found 45 periodic configuration(s) for release 4.17
Missing 12 configuration(s) for release 4.18 (26.7%)
Existing 33 configuration(s) for release 4.18 (73.3%)

Missing Configurations (need migration):
-----------------------------------------
1. ci-operator/config/openshift/cloud-credential-operator/openshift-cloud-credential-operator-release-4.18__periodics.yaml
2. ci-operator/config/openshift/cluster-etcd-operator/openshift-cluster-etcd-operator-release-4.18__periodics.yaml
3. ci-operator/config/openshift/cluster-storage-operator/openshift-cluster-storage-operator-release-4.18__periodics.yaml
... (9 more)

Existing Configurations (already migrated):
--------------------------------------------
33 configuration(s) already exist for release 4.18

Next Steps:
-----------
To migrate missing configurations, run:
  /migrate-variant-periodics 4.17 4.18 ci-operator/config/openshift

To migrate specific repositories, run:
  /migrate-variant-periodics 4.17 4.18 ci-operator/config/openshift/cloud-credential-operator
```
