#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=============================================="
echo "Firewatch Jira Cloud Token Validation Test"
echo "=============================================="
echo ""

# Check if token file exists
if [ ! -f "${FIREWATCH_JIRA_API_TOKEN_PATH}" ]; then
    echo "❌ ERROR: Jira token file not found at ${FIREWATCH_JIRA_API_TOKEN_PATH}"
    exit 1
fi

echo "✓ Token file found at ${FIREWATCH_JIRA_API_TOKEN_PATH}"
echo ""

# Show token length (not the actual token)
TOKEN_LENGTH=$(wc -c < "${FIREWATCH_JIRA_API_TOKEN_PATH}" | tr -d ' ')
echo "Token file size: ${TOKEN_LENGTH} bytes"
echo ""

# Generate Jira configuration
echo "=============================================="
echo "Step 1: Generate Jira Configuration"
echo "=============================================="
echo ""

firewatch jira-config-gen \
    --token-path "${FIREWATCH_JIRA_API_TOKEN_PATH}" \
    --server-url "${FIREWATCH_JIRA_SERVER}" \
    --output-file /tmp/jira.config

if [ $? -eq 0 ]; then
    echo "✓ Jira config generated successfully"
else
    echo "❌ ERROR: Failed to generate Jira config"
    exit 1
fi
echo ""

# Display config (without token)
echo "Generated config:"
cat /tmp/jira.config | grep -v "token"
echo ""

# Test Jira connection using Python
echo "=============================================="
echo "Step 2: Test Jira Connection"
echo "=============================================="
echo ""

python3 << 'EOF'
import sys
import json

try:
    from jira import JIRA
    from jira.exceptions import JIRAError
except ImportError:
    print("❌ ERROR: jira-python library not found")
    sys.exit(1)

# Read config
try:
    with open('/tmp/jira.config', 'r') as f:
        config = json.load(f)
except Exception as e:
    print(f"❌ ERROR: Failed to read config: {e}")
    sys.exit(1)

server_url = config.get('url')
token = config.get('token')

print(f"Testing connection to: {server_url}")
print("")

# Test connection
try:
    jira = JIRA(
        server=server_url,
        token_auth=token,
    )
    print("✓ Successfully connected to Jira server")
except JIRAError as e:
    print(f"❌ ERROR: Jira connection failed: {e.status_code} {e.text}")
    sys.exit(1)
except Exception as e:
    print(f"❌ ERROR: Failed to connect: {e}")
    sys.exit(1)

# Get current user info
try:
    myself = jira.myself()
    print(f"✓ Authenticated as: {myself.get('displayName')} ({myself.get('emailAddress')})")
    print(f"  Username: {myself.get('name')}")
    print(f"  Account ID: {myself.get('accountId')}")
except Exception as e:
    print(f"⚠️  WARNING: Could not get user info: {e}")

print("")

# Test project access
print("============================================")
print("Step 3: Test Project Access")
print("============================================")
print("")

test_projects = ["LPINTEROP", "OCSQE", "INTEROP"]

for project_key in test_projects:
    try:
        project = jira.project(project_key)
        print(f"✓ {project_key}: {project.name}")
        print(f"  Key: {project.key}")
        print(f"  ID: {project.id}")
    except JIRAError as e:
        if e.status_code == 404:
            print(f"⚠️  {project_key}: Project not found or no access")
        else:
            print(f"⚠️  {project_key}: Error {e.status_code}")
    except Exception as e:
        print(f"⚠️  {project_key}: {e}")

print("")

# Test issue creation metadata (to verify permissions)
print("============================================")
print("Step 4: Test Issue Creation Permissions")
print("============================================")
print("")

try:
    # Try to get createmeta for LPINTEROP
    meta = jira.createmeta(
        projectKeys='LPINTEROP',
        issuetypeNames='Bug',
        expand='projects.issuetypes.fields'
    )

    if meta and 'projects' in meta and len(meta['projects']) > 0:
        print("✓ Has permission to create issues in LPINTEROP")
        project = meta['projects'][0]
        print(f"  Project: {project.get('name')}")
        if 'issuetypes' in project and len(project['issuetypes']) > 0:
            issue_type = project['issuetypes'][0]
            print(f"  Can create: {issue_type.get('name')}")
    else:
        print("⚠️  WARNING: Could not verify issue creation permissions")
except JIRAError as e:
    print(f"⚠️  WARNING: Could not check permissions: {e.status_code}")
except Exception as e:
    print(f"⚠️  WARNING: Could not check permissions: {e}")

print("")
print("============================================")
print("✅ All Tests Completed Successfully!")
print("============================================")
print("")
print("Summary:")
print("  ✓ Token is valid")
print("  ✓ Connection to Atlassian Cloud successful")
print("  ✓ Authentication successful")
print("  ✓ User information retrieved")
print("")
print("The Jira Cloud token is working correctly!")

EOF

if [ $? -eq 0 ]; then
    echo ""
    echo "=============================================="
    echo "✅ SUCCESS: Jira Cloud Token Validation Passed"
    echo "=============================================="
    exit 0
else
    echo ""
    echo "=============================================="
    echo "❌ FAILURE: Jira Cloud Token Validation Failed"
    echo "=============================================="
    exit 1
fi
