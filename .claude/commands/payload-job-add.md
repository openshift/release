---
description: Add a new CI job to a release payload configuration
args: "[release] [stream] [arch]"
allowed-tools: Read, Edit, Bash(make release-controllers), AskUserQuestion
---

# Add Job to Release Payload

You are helping the user add a new CI job to a release payload configuration.

## Command Arguments

This command accepts optional arguments: `/payload-job-add [release] [stream] [arch]`
- If arguments are provided (e.g., `/payload-job-add 4.21 nightly` or `/payload-job-add 4.21 nightly arm64`), use them directly
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

2. **Read the release file**: Load the JSON file to see the existing structure.

3. **Gather job information**: Ask the user for:
   - **Prow job name**: The full name of the periodic Prow job (e.g., "periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-ovn-fips")

4. **Generate job key**: Automatically generate the job key from the Prow job name by:
   - Removing common prefixes like "periodic-ci-openshift-release-master-nightly-{version}-", "periodic-ci-openshift-release-master-ci-{version}-", etc.
   - What remains after removing the prefix is typically the job key
   - Remove leading "e2e-" prefix from the generated key if present (e.g., `e2e-aws-ovn-fips` → `aws-ovn-fips`)
   - For upgrade jobs, add the appropriate suffix to the key:
     - If job name contains "upgrade-from-stable-{version}" (e.g., "upgrade-from-stable-4.20"), it's a **minor upgrade** - add `-{release}-minor` to the key (e.g., `gcp-ovn-upgrade-4.21-minor`)
     - If job name contains "upgrade" but NOT "from-stable", it's a **micro upgrade** - add `-{release}-micro` to the key (e.g., `aggregated-aws-ovn-upgrade-4.21-micro-fips`)
   - Examples:
     - `periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-ovn-fips` → `aws-ovn-fips`
     - `periodic-ci-openshift-release-master-ci-4.21-e2e-gcp-ovn-upgrade` → `gcp-ovn-upgrade-micro` (if 4.21)
     - `periodic-ci-openshift-release-master-ci-4.21-upgrade-from-stable-4.20-e2e-gcp-ovn-upgrade` → `gcp-ovn-upgrade-4.21-minor`
     - `periodic-ci-openshift-hypershift-release-4.21-periodics-e2e-aws-ovn-conformance` → `hypershift-ovn-conformance-4.21`
   - Show the generated key to the user and ask if they want to use it or provide a custom key

5. **Detect and configure upgrade settings automatically**:
   - Check if the Prow job name contains "upgrade"
   - If it's an upgrade job, add `"upgrade": true`
   - Check if the job name contains "upgrade-from-stable-" or "-from-stable-":
     - **Minor upgrade** (has "from-stable"):
       - Extract the version being upgraded from (e.g., "4.20" from "upgrade-from-stable-4.20")
       - Add upgradeFromRelease configuration:
         ```json
         "upgradeFromRelease": {
           "candidate": {
             "stream": "nightly",
             "version": "4.20"
           }
         }
         ```
     - **Micro upgrade** (no "from-stable"): Only add `"upgrade": true`, do NOT add upgradeFromRelease

6. **Configure other job settings**:
   - **Job status**: ALWAYS add jobs as informing (with `"optional": true`). Jobs can be promoted to blocking later using the `/payload-job-promote` command if needed. Never add jobs as blocking initially.
   - **Is this an aggregated job?**: Ask the user if this is an aggregated job. If yes, automatically add aggregatedProwJob configuration with analysisJobCount of 10 (always 10, never ask for count)

7. **Add the job**:
   - Add the new job entry to the `verify` section of the JSON file
   - Ensure proper JSON formatting with correct commas
   - Place the job in alphabetical order within the verify section if possible
   - Structure for blocking job:
     ```json
     "job-key": {
       "maxRetries": 2,
       "prowJob": {
         "name": "prow-job-name"
       },
       "upgrade": true,   // only if upgrade job
       "aggregatedProwJob": {  // only if aggregated
         "analysisJobCount": 10
       }
     }
     ```
   - Structure for informing job:
     ```json
     "job-key": {
       "optional": true,
       "prowJob": {
         "name": "prow-job-name"
       },
       "upgrade": true,   // only if upgrade job
       "aggregatedProwJob": {  // only if aggregated
         "analysisJobCount": 10
       }
     }
     ```

8. **Run make release-controllers**: Create a Python virtual environment if needed and execute `make release-controllers` to regenerate the release controller configurations. First check if `venv` directory exists - if not, create it with `python3 -m venv venv`. Then activate it with `source venv/bin/activate`, and finally run `make release-controllers`.

9. **Confirm completion**: Let the user know the job has been added and the configurations have been regenerated. Show them the job key and Prow job name that was added.

## Important notes:

- **Only modify files in `core-services/release-controller/_releases/` - DO NOT modify files in the `priv` directory as those are auto-generated**
- **ALWAYS add new jobs as informing** - All new jobs must start with `"optional": true` and should NOT have a maxRetries field. Jobs can be promoted to blocking later if needed.
- Jobs with `"optional": true` are informing (non-blocking) and should NOT have a maxRetries field
- Jobs without `"optional": true` are blocking and MUST have `"maxRetries": 2`
- The JSON formatting must remain valid - be careful with commas
- Handle different stream types correctly (some releases don't have a stream suffix in the filename)
- Maintain alphabetical ordering of jobs in the verify section when possible
- If the generated job key already exists, warn the user and ask if they want to overwrite it or provide a different key

## Example job configurations:

**Simple informing job (all new jobs start this way):**
```json
"aws-ovn": {
  "optional": true,
  "prowJob": {
    "name": "periodic-ci-openshift-release-master-ci-4.21-e2e-aws-ovn"
  }
}
```

**Informing upgrade job with upgradeFromRelease:**
```json
"aws-ovn-upgrade-minor": {
  "optional": true,
  "prowJob": {
    "name": "periodic-ci-openshift-release-master-nightly-4.21-upgrade-from-stable-4.20-e2e-aws-ovn-upgrade"
  },
  "upgrade": true,
  "upgradeFromRelease": {
    "candidate": {
      "stream": "nightly",
      "version": "4.20"
    }
  }
}
```

**Informing aggregated job:**
```json
"aggregated-aws-ovn-upgrade-4.21-micro-fips": {
  "optional": true,
  "prowJob": {
    "name": "periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-ovn-upgrade-fips"
  },
  "upgrade": true,
  "aggregatedProwJob": {
    "analysisJobCount": 10
  }
}
```
