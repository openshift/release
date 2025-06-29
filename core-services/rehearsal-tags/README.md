# Tag-Based Job Rehearsals

This directory contains configuration for tag-based job rehearsals in the `pj-rehearse` Prow plugin.

## Overview

Tag-based rehearsals allow you to run groups of related jobs with a single command, rather than having to specify individual job names. This is useful for testing specific components or categories of tests.

## Usage

In a PR comment, use:
```
/pj-rehearse {tag-name}
```

For example:
- `/pj-rehearse tnf` - Run all Test Network Function related jobs
- `/pj-rehearse telco` - Run all telco-related jobs  
- `/pj-rehearse storage` - Run all storage-related jobs
- `/pj-rehearse microshift` - Run all MicroShift-related jobs

## Configuration

Tags are configured in `_config.yaml` and deployed as a ConfigMap to the `pj-rehearse` plugin.

### Selector Types

Each tag can have multiple selectors. A job matches the tag if it satisfies **any** selector (OR logic):

1. **`job_name_pattern`** - Regex pattern matching the job name
   ```yaml
   - job_name_pattern: ".*-tnf-.*"
   ```

2. **`job_name`** - Exact job name match
   ```yaml
   - job_name: "pull-ci-openshift-origin-main-e2e-aws-ovn-upgrade"
   ```

3. **`cluster_profile`** - Matches jobs with specific cluster profile labels
   ```yaml
   - cluster_profile: "aws-telco"
   ```

4. **`file_path_pattern`** - Regex pattern matching the repository path (org/repo format)
   ```yaml
   - file_path_pattern: ".*/microshift/.*"
   ```

### Adding New Tags

To add a new tag:

1. Edit `clusters/app.ci/prow/02_config/pj-rehearse-tag-config.yaml`
2. Add your tag under the `tags:` section
3. Define selectors that identify the jobs you want to include
4. Submit a PR to openshift/release

Example:
```yaml
- name: my-component
  selectors:
    - job_name_pattern: ".*my-component.*"
    - file_path_pattern: ".*/my-org/my-component/.*"
```

## Important Notes

- **Only affected jobs are considered**: Tag filtering only applies to jobs that are already affected by your PR changes
- **Presubmits only**: Periodic jobs cannot be rehearsed via tags
- **OR logic**: A job matches if it satisfies any selector, not all selectors
- **Regex patterns**: Use proper regex syntax in pattern selectors

## Available Tags

Current available tags:

- **`tnf`** - Test Network Function jobs
- **`telco`** - Telco and 5G related jobs  
- **`storage`** - Storage and CSI driver jobs
- **`microshift`** - MicroShift related jobs
- **`hypershift`** - HyperShift related jobs
- **`ovn`** - OVN networking jobs
- **`important-optional-tests`** - Curated list of important optional tests

See `_config.yaml` for the complete and up-to-date configuration. 