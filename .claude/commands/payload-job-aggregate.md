---
description: Convert a release payload job to run multiple times with statistical analysis
args: "[release] [stream] [arch]"
allowed-tools: Read, Edit, Bash(make release-controllers), AskUserQuestion
---

# Aggregate Release Payload Job

You are helping the user convert a release payload job to an aggregated job that runs multiple times with statistical analysis.

## Command Arguments

This command accepts optional arguments: `/payload-job-aggregate [release] [stream] [arch]`
- If arguments are provided (e.g., `/payload-job-aggregate 4.21 nightly` or `/payload-job-aggregate 4.21 nightly arm64`), use them directly
- If no arguments are provided, prompt the user for the information

## Steps to follow:

1. **Get release, stream, and architecture**:
   - If ARGUMENTS are provided, parse them to extract release version, stream type, and optional architecture
   - If no ARGUMENTS are provided, ask the user for:
     - Release version (e.g., "4.21", "4.20")
     - Stream type (e.g., "nightly", "ci", "stable")
     - Architecture (optional, defaults to amd64 if not provided)

   - Supported architectures: `arm64`, `s390x`, `ppc64le`, `multi`, or leave blank for `amd64` (default)

   Construct the file path based on stream and architecture:
   - For `nightly` stream:
     - Default amd64: `core-services/release-controller/_releases/release-ocp-{version}.json`
     - Specific arch: `core-services/release-controller/_releases/release-ocp-{version}-{arch}.json`
   - For other streams (ci, stable, etc.):
     - Default amd64: `core-services/release-controller/_releases/release-ocp-{version}-{stream}.json`
     - Specific arch: `core-services/release-controller/_releases/release-ocp-{version}-{stream}-{arch}.json`

   Note: When architecture is specified and is not amd64, append `-{arch}` to the filename (after stream if present)

2. **Read the release file**: Load the JSON file to find all jobs in the `verify` section.

3. **Find non-aggregated jobs**: Identify all jobs that do NOT have `"aggregatedProwJob"` in their configuration. These are regular jobs that can be aggregated.

4. **Present job selection**: Display a numbered list of all non-aggregated jobs found in the release file, showing both the job key and the Prow job name. Organize jobs into logical categories (no more than 7 groups) based on platform or distinguishing characteristics (e.g., Agent, AWS, Azure, GCP, Bare Metal, vSphere, Managed & Specialized). Maintain continuous numbering across all categories. Ask the user to provide the number of the job they want to aggregate.

5. **Aggregate the job**: Edit the selected job's configuration to:
   - Add the `"aggregated-"` prefix to the job key name (e.g., `"gcp-ovn-upgrade"` becomes `"aggregated-gcp-ovn-upgrade"`)
   - Add `"aggregatedProwJob": { "analysisJobCount": 10 },` (always use 10 for the analysis job count)
   - Ensure blocking jobs (those without `"optional": true`) have `"maxRetries"` set (typically 2) - add it if not already present
   - Keep all existing fields like `"optional"`, `"upgrade"`, `"upgradeFromRelease"`, etc.
   - Maintain proper JSON formatting with commas

6. **Run make release-controllers**: Create a Python virtual environment if needed and execute `make release-controllers` to regenerate the release controller configurations. First check if `venv` directory exists - if not, create it with `python3 -m venv venv`. Then activate it with `source venv/bin/activate`, and finally run `make release-controllers`.

7. **Confirm completion**: Let the user know the job has been converted to an aggregated job and explain that it will now run 10 times and statistically analyze the results.

## Important notes:

- **Only modify files in `core-services/release-controller/_releases/` - DO NOT modify files in the `priv` directory as those are auto-generated**
- Aggregating requires adding the `"aggregated-"` prefix to the job key name
- Aggregated jobs always run 10 times and use statistical analysis to determine pass/fail
- The `analysisJobCount` field is always set to 10 - do not prompt the user for this value
- Blocking jobs (without `"optional": true`) must have `"maxRetries"` configured (typically 2)
- The job can be both aggregated and blocking, or aggregated and informing (with `"optional": true`)
- Preserve all existing fields when adding aggregation
- The JSON formatting must remain valid - be careful with commas
- Handle different stream types correctly (some releases don't have a stream suffix in the filename)
