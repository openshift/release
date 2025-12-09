#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "******** Starting CI Job Failure Analysis..."

# Check if ARTIFACT_DIR is set and exists
if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    echo "ERROR: ARTIFACT_DIR is not set"
    exit 1
fi

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
    echo "ERROR: ARTIFACT_DIR does not exist: ${ARTIFACT_DIR}"
    exit 1
fi

echo "******** Working directory: $(pwd)"

# Check required environment variables for GCS download
if [[ -z "${JOB_NAME:-}" ]]; then
    echo "ERROR: JOB_NAME is not set"
    exit 1
fi

if [[ -z "${BUILD_ID:-}" ]]; then
    echo "ERROR: BUILD_ID is not set"
    exit 1
fi

# Allowlist of jobs - only run Claude analysis on these critical jobs
ALLOWED_JOBS=(
    "periodic-ci-openshift-hypershift-release-4.21-periodics-e2e-aws-ovn-conformance"
    "periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance"
    "periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance-serial"
    "periodic-ci-openshift-release-master-ci-4.21-e2e-aws-ovn-techpreview"
    "periodic-ci-openshift-release-master-ci-4.21-e2e-aws-ovn-techpreview-serial-1of3"
    "periodic-ci-openshift-release-master-ci-4.21-e2e-aws-ovn-techpreview-serial-2of3"
    "periodic-ci-openshift-release-master-ci-4.21-e2e-aws-ovn-techpreview-serial-3of3"
    "periodic-ci-openshift-release-master-ci-4.21-e2e-aws-upgrade-ovn-single-node"
    "periodic-ci-openshift-release-master-ci-4.21-e2e-azure-ovn-upgrade"
    "periodic-ci-openshift-release-master-ci-4.21-upgrade-from-stable-4.20-e2e-gcp-ovn-rt-upgrade"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-driver-toolkit"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-ovn-serial-1of2"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-ovn-serial-2of2"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-aws-ovn-upgrade-fips"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-metal-ipi-ovn-bm"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-metal-ipi-ovn-ipv6"
    "periodic-ci-openshift-release-master-nightly-4.21-e2e-rosa-sts-ovn"
    "periodic-ci-openshift-release-master-ci-4.21-claude-post-analysis-test"
)

# Check if current job matches allowlist
echo "******** Checking job allowlist..."
echo "******** Current job: ${JOB_NAME}"

JOB_MATCHED=0
for allowed_job in "${ALLOWED_JOBS[@]}"; do
    if [[ "${JOB_NAME}" == "${allowed_job}" ]]; then
        echo "******** Job matched allowlist: ${allowed_job}"
        JOB_MATCHED=1
        break
    fi
done

if [[ ${JOB_MATCHED} -eq 0 ]]; then
    echo "******** Job does not match allowlist filters. Skipping Claude analysis."
    exit 0
fi

echo "******** Job is in allowlist. Proceeding with analysis..."

# Create GCS artifact tool with list and get commands
echo "******** Creating GCS artifact tool..."
cat > gcs_tool.py << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
GCS artifact tool with list and get commands.
Uses the Google Cloud Storage JSON API with anonymous access.

Usage:
  python3 gcs_tool.py list              # List all available artifacts
  python3 gcs_tool.py get <files...>    # Download specific files
"""

import os
import sys
import urllib.request
import urllib.error
import json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import quote

# GCS bucket details - set by environment variables
BUCKET = "test-platform-results"
JOB_NAME = os.environ.get('JOB_NAME', '')
BUILD_ID = os.environ.get('BUILD_ID', '')
PREFIX = f"logs/{JOB_NAME}/{BUILD_ID}/artifacts"
BASE_URL = f"https://storage.googleapis.com/storage/v1/b/{BUCKET}/o"
DOWNLOAD_URL = "https://storage.googleapis.com"
OUTPUT_DIR = "."

def list_all_objects(prefix):
    """List all objects in GCS bucket with given prefix."""
    all_items = []
    page_token = None

    while True:
        params = {'prefix': prefix, 'delimiter': ''}
        if page_token:
            params['pageToken'] = page_token

        query_string = '&'.join(f"{k}={quote(str(v))}" for k, v in params.items())
        url = f"{BASE_URL}?{query_string}"

        try:
            with urllib.request.urlopen(url) as response:
                result = json.loads(response.read().decode())
        except urllib.error.HTTPError as e:
            print(f"Error listing objects: {e}", file=sys.stderr)
            sys.exit(1)

        if 'items' in result:
            all_items.extend(result['items'])

        page_token = result.get('nextPageToken')
        if not page_token:
            break

    return all_items

def download_file(relative_path):
    """Download a single file from GCS by relative path."""
    object_name = f"{PREFIX}/{relative_path}"
    local_path = Path(OUTPUT_DIR) / relative_path

    # Create parent directory
    local_path.parent.mkdir(parents=True, exist_ok=True)

    # Download URL
    download_url = f"{DOWNLOAD_URL}/{BUCKET}/{quote(object_name, safe='')}"

    try:
        urllib.request.urlretrieve(download_url, local_path)
        return (relative_path, True, None)
    except Exception as e:
        return (relative_path, False, str(e))

def cmd_list():
    """List all available artifacts."""
    items = list_all_objects(PREFIX)

    for item in items:
        relative_path = item['name'].replace(PREFIX, '').lstrip('/')
        if relative_path:
            print(relative_path)

    print(f"\nTotal files: {len(items)}", file=sys.stderr)

def cmd_get(files):
    """Download specific files."""
    if not files:
        print("Error: No files specified", file=sys.stderr)
        sys.exit(1)

    print(f"Downloading {len(files)} file(s)...", file=sys.stderr)

    successful = 0
    failed = 0

    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(download_file, f): f for f in files}

        for future in as_completed(futures):
            filepath, success, error = future.result()
            if success:
                print(f"✓ {filepath}", file=sys.stderr)
                successful += 1
            else:
                print(f"✗ {filepath}: {error}", file=sys.stderr)
                failed += 1

    print(f"\nDownloaded: {successful}, Failed: {failed}", file=sys.stderr)

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]

    if command == "list":
        cmd_list()
    elif command == "get":
        cmd_get(sys.argv[2:])
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(__doc__)
        sys.exit(1)

if __name__ == "__main__":
    main()
PYTHON_EOF

chmod +x gcs_tool.py

echo "******** GCS tool created. Available commands:"
echo "  ./gcs_tool.py list              # List all artifacts"
echo "  ./gcs_tool.py get <files...>    # Download specific files"

# Define the output HTML file
OUTPUT_HTML="${ARTIFACT_DIR}/claude-analysis-summary.html"

# Create temporary settings file with required permissions
SETTINGS_FILE=$(mktemp)
trap 'rm -f "${SETTINGS_FILE}"' EXIT

cat > "${SETTINGS_FILE}" << EOF
{
  "permissions": {
    "allow": [
      "Write(*)",
      "Edit(*)",
      "Read(*)",
      "Glob(*)",
      "Grep(*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(cat:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(ls:*)",
      "Bash(wc:*)",
      "Bash(sort:*)",
      "Bash(uniq:*)",
      "Bash(sed:*)",
      "Bash(awk:*)",
      "Bash(jq:*)",
      "Bash(xmllint:*)",
      "Bash(file:*)",
      "Bash(stat:*)",
      "Bash(tar:*)",
      "Bash(strings:*)",
      "Bash(basename:*)",
      "Bash(dirname:*)",
      "Bash(diff:*)",
      "Bash(cut:*)",
      "Bash(split:*)",
      "Bash(tr:*)",
      "Bash(./gcs_tool.py:*)"
    ],
    "deny": [],
    "ask": [],
    "defaultMode": "acceptEdits"
  }
}
EOF

# Ensure prow-job plugin is available, with its various prow-job skills
claude plugin install prow-job@ai-helpers

# Analyze the job using Claude and generate HTML report
claude --verbose --output-format=stream-json --settings "${SETTINGS_FILE}" -p "You are analyzing a CI job. Please examine the artifacts and create an HTML analysis report to determine if the job failed, and if so - why.  You may have skills that help you analyze prow jobs, and note that if they suggest retrieving artifacts form GCS, you MUST use the tools specified here instead.

**DOWNLOADING ARTIFACTS**:
Artifacts are stored in GCS and must be downloaded before analysis. Use the gcs_tool.py script:

  # List all available artifacts
  ./gcs_tool.py list

  # Download specific files (you can specify multiple files)
  ./gcs_tool.py get <file1> <file2> ...

Examples:
  ./gcs_tool.py list | grep finished.json
  ./gcs_tool.py get e2e-metal-ipi/finished.json
  ./gcs_tool.py get e2e-metal-ipi/artifacts/junit_operator.xml

**ANALYSIS WORKFLOW**:

Before beginning your analysis, you MUST determine if the job failed.
1. First, list artifacts to see what's available
2. Download finished.json files to check for failures
3. If failures found, download relevant logs and test results for deeper analysis

1. **Job Failure Detection**: Check for finished.json files to determine which CI steps failed
   - Download and examine finished.json files for each step
   - If an install step failed: Download installation logs to identify why cluster installation failed. Use skills related to analyzing install failures, if any.
   - If a test step failed: Download JUnit XML files to identify which specific tests failed. Use skills related to analyzing test failures, if any.
   - If other steps failed: Download relevant logs for that step
   - If ALL finished.json indicate SUCCESS, then this job did not fail - state this and stop further analysis!

2. **Test Failure Analysis** (if tests failed):
   - Download and parse JUnit XML files to list failed tests
   - Identify patterns in test failures
   - Extract error messages and stack traces
   - Note that a test that has at least 1 success and 1 failure, is considered a flake and would not cause a job to fail.

3. **Log Analysis**:
   - Download logs from must-gather, gather-extra, logbundle directories if present
   - Look for error patterns, panics, or warnings
   - Check pod logs for failures

4. **Root Cause Analysis**:
   - Synthesize findings to determine the likely root cause
   - Provide specific file paths and line numbers where relevant
   - Suggest potential fixes if obvious

**IMPORTANT CONSTRAINTS**:
- You MUST use ./gcs_tool.py to download artifacts before analyzing them
- Only download files you actually need for the analysis - be selective
- Use bash, grep, find, and file reading tools for analysis
- Downloaded files will be in the current working directory

**HTML OUTPUT REQUIREMENTS**:
You MUST create an HTML file at ${OUTPUT_HTML} with the following structure:

\`\`\`html
<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>CI Job Failure Analysis</title>
    <style>
        body {
            font-family: system-ui, sans-serif;
            line-height: 1.5;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        h1 { border-bottom: 2px solid #333; padding-bottom: 10px; }
        h2 { color: #0066cc; margin-top: 30px; }
        pre { background: #f5f5f5; padding: 10px; overflow-x: auto; }
        table { border-collapse: collapse; width: 100%; margin: 15px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background: #f0f0f0; }
    </style>
</head>
<body>
    <h1>CI Job Failure Analysis</h1>
    <p><em>Generated: [TIMESTAMP]</em></p>

    <h2>Summary</h2>
    [Brief summary of what failed. You must include a disclaimer here the content is AI-generated and may contain errors.]

    <h2>Failed Steps</h2>
    [Details from finished.json]

    <h2>Test Failures</h2>
    [JUnit analysis if applicable]

    <h2>Log Analysis</h2>
    [Key findings from logs]

    <h2>Root Cause</h2>
    [Root cause analysis]

    <h2>Recommendations</h2>
    [Suggested fixes]
</body>
</html>
\`\`\`

Use the Write tool to create this HTML file with your actual analysis content. Keep formatting simple and consistent.

Please begin your analysis now and create the HTML report."

echo "******** CI Job Failure Analysis Complete"
echo "******** HTML report generated at: ${OUTPUT_HTML}"
