---
name: migrate-variant-periodics
description: Migrate OpenShift periodic CI job definitions from one release version to another by copying and transforming YAML configuration files
parameters:
  - name: from_release
    description: Source release version to migrate from (e.g., "4.17", "4.18")
    required: true
  - name: to_release
    description: Target release version to migrate to (e.g., "4.18", "4.19")
    required: true
  - name: path
    description: Optional directory path to search for periodic files (default is ci-operator/config/)
    required: false
  - name: skip_existing
    description: Optional flag "--skip-existing" to automatically skip existing target files without prompting
    required: false
---

You are helping users migrate OpenShift periodic CI job definitions from one release version to another.

## Context

Periodic jobs are CI tests that run on a schedule (via cron) or after a specified interval since last execution rather than on pull requests. These are defined in files following the pattern: `*-release-{major.minor}__periodics.yaml` in the `ci-operator/config/` directory.

## Your Task

The user wants to migrate periodic job configurations:
- **From release**: {{from_release}}
- **To release**: {{to_release}}
{{#if path}}- **Search path**: {{path}}{{else}}- **Search path**: ci-operator/config/ (default){{/if}}
{{#if skip_existing}}- **Skip existing**: Yes (automatically skip existing files without prompting){{else}}- **Skip existing**: No (prompt for each existing file){{/if}}

## Implementation Steps

### 1. Verify git branch and get user confirmation
- Check current git branch using `git rev-parse --abbrev-ref HEAD`
- Display branch name to user
- Warn if on main/master branch
- Ask user to confirm they want to proceed with modifications on this branch
- Exit immediately if user declines

### 2. Parse and normalize version arguments
- Normalize from_release and to_release to {major}.{minor} format
- Handle formats: "4.17", "release-4.17", "4.17.0" → "4.17"
- Validate version format (must be X.Y)
- Determine search path (use provided path or default to ci-operator/config/)

### 3. Find source periodic files
- Search for files matching pattern: `*-release-{from_release}__periodics.yaml`
- Use find command or glob pattern
- **CRITICAL**: Automatically exclude ALL files under `ci-operator/config/openshift-priv/` from the list
- Display list of found files with count (excluding openshift-priv)
- If any openshift-priv files were excluded, inform the user with a warning
- Ask user for confirmation before proceeding
- If no files found, inform user and exit

### 4. Check for existing target files
- For each source file, construct target filename
- Check if target file already exists
- Build migration plan:
  {{#if skip_existing}}
  - If --skip-existing flag is set:
    - Automatically skip all existing files without prompting
    - Only include non-existing files in migration plan
  {{else}}
  - If --skip-existing flag is NOT set:
    - Ask user whether to overwrite each existing file using AskUserQuestion tool
    - Build list of files to migrate based on user responses
  {{/if}}
- Display migration plan summary

### 5. Migrate each file using the migration script
For each file in the migration plan:

a. **Use the migration script** `.claude/scripts/migrate_periodic_file.py`:
   - Call the script with: `python3 .claude/scripts/migrate_periodic_file.py <source_file> <from_version> <to_version>`
   - The script automatically:
     - Transforms all version references (base images, builder tags, registry paths, release names, version strings, branch metadata)
     - Regenerates randomized cron schedules to avoid thundering herd (keeps interval-based schedules unchanged)
     - Creates the target file in the same directory with the new version in the filename
   - Example: `python3 .claude/scripts/migrate_periodic_file.py ci-operator/config/openshift/etcd/openshift-etcd-release-4.21__periodics.yaml 4.21 4.22`

b. **Track result**: success or failure with details from the script output

### 6. Generate migration summary
- Count successful migrations
- Count skipped files (already existed)
- Count failed migrations with error details
- Provide file-level details for each migration

### 7. Run make update
After successful migration:
- Run `make update` to regenerate all downstream artifacts
- This runs: `make jobs`, `make ci-operator-config`, `make prow-config`, `make registry-metadata`, `make release-controllers`, `make boskos-config`
- Display the output to the user
- If `make update` fails, report the error and suggest manual intervention
- Track the time taken for the update process

### 8. Provide next steps
Suggest to the user:
```
Next steps:
1. Review the generated changes: git status && git diff --stat
2. Verify the configuration is correct
3. Test the changes if possible
4. Create a pull request with both the migrated configs and generated job files
```

## Important Notes

- **CRITICAL - openshift-priv repositories**: NEVER create, copy, or modify ANY files under `ci-operator/config/openshift-priv/` during migration. These are private repositories with special security considerations and must be handled separately by authorized personnel.
- **Interval schedules**: Preserve existing interval schedules and do not modify the interval or convert to cron schedule
- **Cron schedules**: Always regenerate randomized cron schedules to distribute load and avoid thundering herd problems
- **Single schedule**: Only use interval or cron schedules do not use both
- **Version consistency**: Update ALL version references consistently throughout the file
- **YAML formatting**: Use Write tool which will handle YAML formatting
- **Error handling**: Handle file read/write errors gracefully and report them clearly
- **Golang versions**: Preserve golang versions in builder tags - only update the OpenShift release portion
- **Cluster profiles**: Preserve existing cluster profile configurations

## Example Transformations

From 4.17 to 4.18:

```yaml
# Before (4.17)
base_images:
  ocp_4_17_base-rhel9:
    name: "4.17"
    namespace: ocp
    tag: base-rhel9
  ocp_builder_rhel-9-golang-1.22-openshift-4.17:
    name: builder
    namespace: ocp
    tag: rhel-9-golang-1.22-openshift-4.17

releases:
  initial:
    integration:
      name: "4.17"
      namespace: ocp
  latest:
    candidate:
      product: ocp
      stream: ci
      version: "4.17"

tests:
- as: e2e-aws
  cron: "15 3 5 * *"  # Monthly on 5th at 3:15am

zz_generated_metadata:
  branch: release-4.17
  org: openshift
  repo: cluster-authentication-operator
  variant: periodics

# After (4.18)
base_images:
  ocp_4_18_base-rhel9:
    name: "4.18"
    namespace: ocp
    tag: base-rhel9
  ocp_builder_rhel-9-golang-1.22-openshift-4.18:
    name: builder
    namespace: ocp
    tag: rhel-9-golang-1.22-openshift-4.18

releases:
  initial:
    integration:
      name: "4.18"
      namespace: ocp
  latest:
    candidate:
      product: ocp
      stream: ci
      version: "4.18"

tests:
- as: e2e-aws
  cron: "42 7 12 * *"  # New random: Monthly on 12th at 7:42am

zz_generated_metadata:
  branch: release-4.18
  org: openshift
  repo: cluster-authentication-operator
  variant: periodics
```

## Usage Examples

```
# Migrate all periodic jobs from 4.17 to 4.18
/migrate-variant-periodics 4.17 4.18

# Migrate specific repository
/migrate-variant-periodics 4.18 4.19 ci-operator/config/openshift/etcd

# Migrate entire organization
/migrate-variant-periodics 4.19 4.20 ci-operator/config/openshift

# Migrate with automatic skip of existing files
/migrate-variant-periodics 4.17 4.18 --skip-existing

# Migrate specific path and skip existing
/migrate-variant-periodics 4.18 4.19 ci-operator/config/openshift --skip-existing
```
