# Resolving effective environment variables of a given job
---
name: effective-env
description: Resolve and display the effective environment variables for a specific CI job in a table format
allowed-tools: ["Read", "Bash(find:*)", "Bash(grep:*)"]
parameters:
  - name: job_name
    description: The job name (value in the 'as' field in ci-operator/config YAML files)
    required: true
  - name: component_name
    description: |
      Optional component name to narrow down job configs. Examples:
      - 'hypershift' -> searches ci-operator/config/openshift/hypershift and ci-operator/config/openshift-priv/hypershift
      - 'jboss-eap' -> searches ci-operator/config/jboss-eap-qe
      - 'openshift/hypershift' -> searches only ci-operator/config/openshift/hypershift
      If not provided, searches all job configs in ci-operator/config directory.
    required: false
  - name: version
    description: |
      Optional version(s) to filter job configs. Can be:
      - Single version: '4.21'
      - Multiple versions (comma or space-separated): '4.21,4.20' or '4.21 4.20'
      - If not set, all versions are included (may prompt for confirmation if >2 found)
      Matches files like 'openshift-hypershift-release-4.21__periodics.yaml' and 'openshift-hypershift-release-4.21.yaml'.
    required: false
  - name: filter
    description: |
      Optional case-insensitive filter to show only environment variables matching this pattern.
      Example: 'lvm' shows LVM_OPERATOR_SUB_CHANNEL, LVM_CATALOG_SOURCE, etc.
      Example: 'metallb' shows METALLB_OPERATOR_SUB_SOURCE, METALLB_OPERATOR_SUB_CHANNEL, etc.
    required: false
---

Find matching CI config files, resolve environment variables, and display a formatted summary:

**Step 1: Find matching config files**

Use the Grep tool to search for files containing the job name in the `as:` field:
- Pattern: `^\s*-?\s*as:\s*{{job_name}}\s*$`
- Path: `ci-operator/config`
- Glob filter: Build based on parameters:
  - If `{{component_name}}` is empty: `**/*.yaml`
  - If `{{component_name}}` contains `/`: `**/{{component_name}}/**/*.yaml`
  - Otherwise: `**/*{{component_name}}*/**/*.yaml`
- Output mode: `files_with_matches`
- Do NOT apply version filter in Grep - we'll filter after getting all results

**Step 1.1: Parse and filter versions**

If `{{version}}` parameter is provided:
- Split by comma or space to get multiple versions: `['4.21', '4.20']`
- Filter the found config files to only include those matching any of the specified versions
- Match pattern: `*release-{version}*.yaml` for each version in the list
- Keep files that match at least one version pattern

**Step 1.2: Handle multiple config files**

Count the filtered config files:
- If 0 files: Display error (see Error handling section)
- If 1-2 files: Process all automatically
- If >2 files: Extract unique versions from filenames and ask user to confirm which versions to check:
  - Parse versions from filenames (format: `*release-{version}*.yaml`)
  - Show list of unique versions found
  - Use AskUserQuestion to let user select which versions to process
  - Filter config files based on user's selection

**Step 2: Execute Python script and parse JSON output**

For each selected config file, execute:
```bash
python3 .claude/scripts/effective_env.py "<config_file_path>" "{{job_name}}" {{filter_arg}}
```

Where `{{filter_arg}}` is `--filter {{filter}}` if filter parameter is provided, otherwise empty.

The script outputs JSON with this structure:
```json
{
  "job_name": "job-name",
  "config_file": "path/to/config.yaml",
  "version": "4.21",
  "workflow": "workflow-name",
  "filter": "filter-string or null",
  "total_count": 75,
  "filtered_count": 11,
  "env_vars": [
    {
      "name": "VAR_NAME",
      "value": "value",
      "source": "config|workflow|chain|step",
      "source_file": "source-file.yaml",
      "default_value": "default or null",
      "is_overridden": true|false
    }
  ],
  "overrides": [
    {
      "name": "VAR_NAME",
      "value": "overridden-value",
      "source": "config|workflow|chain",
      "default_value": "original-default"
    }
  ]
}
```

**Step 3: Display formatted summary (REQUIRED FORMAT)**

IMPORTANT: Always use this exact output format for every config file processed.

Parse the JSON output and create a markdown summary with these sections:

**3.1: Header section**
```
## Job: {{job_name}} ({{version}})
- **Config**: {{config_file}}
- **Workflow**: {{workflow}}
```

**3.2: Summary section (ALWAYS INCLUDE)**
```
### Summary
- Total environment variables: {{total_count}}
- Displayed: {{filtered_count}} {{filter_note}}
- Overrides: {{overrides_count}}
```

Where `{{filter_note}}` is:
- If user filtered: "(filtered by: '{{filter}}')"
- If not filtered: ""

**3.3: Environment variables table (ALWAYS USE TABLE FORMAT)**

CRITICAL: Always display as a markdown table with only 2 columns.

```
| Variable | Value |
|----------|-------|
| VAR_NAME | value |
| ...      | ...   |
```

Table formatting rules:
- Truncate values >80 chars to 77 chars + "..."
- Truncate multiline values: show first line + " `<+N more lines>`"
- Mark overridden variables with ⚠️ emoji: `⚠️ VAR_NAME`
- Sort by: overridden first, then alphabetically
- Show ALL variables unless user provided a filter parameter
- Show variable effective value source in the Variable colume with suffix: '(T)', where the T can be: 'config' for job config, 'workflow' for workflow, 'chain' for chain, 'step' for step

**3.4: Key overrides section (ALWAYS INCLUDE IF ANY EXIST)**

If `overrides` array is not empty, add this section:
```
### 🔑 Key Overrides

These variables have been overridden from their step defaults:

| Variable | Override Value | Source | Default Value |
|----------|----------------|--------|---------------|
| VAR_NAME | new-value | config | original-value |
| ...      | ...           | ...    | ... |
```

Sort overrides by source priority (config > workflow > chain)

**Error handling:**
- If no files found, display: "❌ No config files found matching: job={{job_name}}, component={{component_name}}, version={{version}}"
- If Python script fails, check PyYAML dependency: `pip install pyyaml`
- If JSON parsing fails, display the raw output and error message

**Multiple config files:**
- If multiple files selected, process each and separate outputs with horizontal dividers
- Each output must follow the same format (header → summary → table → overrides)
- Display results sequentially, one config file per section

**Examples:**

1. Basic usage (single job, auto-select versions):
   ```
   /effective-env e2e-kubevirt-metal-ovn hypershift
   ```
   Result: Shows all versions, prompts if >2 found

2. Specific version:
   ```
   /effective-env e2e-kubevirt-metal-ovn hypershift 4.21
   ```
   Result: Shows only 4.21 config

3. Multiple versions:
   ```
   /effective-env e2e-kubevirt-metal-ovn hypershift "4.20,4.21"
   ```
   Result: Shows both 4.21 and 4.20 configs

4. With filter:
   ```
   /effective-env e2e-kubevirt-metal-ovn hypershift 4.21 metallb
   ```
   Result: Shows only METALLB* variables for 4.21

5. Multiple versions with filter:
   ```
   /effective-env e2e-kubevirt-metal-ovn hypershift "4.20,4.21" hypershift
   ```
   Result: Shows hypershift* variables for both versions
