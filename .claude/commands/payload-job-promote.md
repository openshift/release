---
description: Promote an informing release payload job to blocking status
args: "[release] [stream] [arch]"
allowed-tools: Read, Edit, Bash(make release-controllers), AskUserQuestion
---

# Promote Release Payload Job to Blocking

You are helping the user promote an informing release payload job to blocking status.

## Command Arguments

This command accepts optional arguments: `/payload-job-promote [release] [stream] [arch]`
- If arguments are provided (e.g., `/payload-job-promote 4.21 nightly` or `/payload-job-promote 4.21 nightly arm64`), use them directly
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

3. **Find informing jobs**: Identify all jobs that have `"optional": true` in their configuration. These are informing jobs.

4. **Present job selection**: Display a numbered list of all informing jobs found in the release file, showing both the job key and the Prow job name. Organize jobs into logical categories (no more than 7 groups) based on platform or distinguishing characteristics (e.g., Agent, AWS, Azure, GCP, Bare Metal, vSphere, Managed & Specialized). Maintain continuous numbering across all categories. Ask the user to provide the number of the job they want to promote.

5. **Promote the job**: Edit the selected job's configuration to:
   - Remove the line containing `"optional": true,` (note: be careful with trailing commas)
   - Add `"maxRetries": 2,` if it doesn't exist, or ensure it's set to 2 if it does exist

6. **Run make release-controllers**: Create a Python virtual environment if needed and execute `make release-controllers` to regenerate the release controller configurations. First check if `venv` directory exists - if not, create it with `python3 -m venv venv`. Then activate it with `source venv/bin/activate`, and finally run `make release-controllers`.

7. **Confirm completion**: Let the user know the job has been promoted and the configurations have been regenerated.

## Important notes:

- **Only modify files in `core-services/release-controller/_releases/` - DO NOT modify files in the `priv` directory as those are auto-generated**
- Jobs with `"optional": true` are informing (non-blocking)
- Jobs without `"optional": true` (or with `"optional": false`) are blocking
- When promoting to blocking, we always set `"maxRetries": 2`
- The JSON formatting must remain valid - be careful with commas
- Handle different stream types correctly (some releases don't have a stream suffix in the filename)
