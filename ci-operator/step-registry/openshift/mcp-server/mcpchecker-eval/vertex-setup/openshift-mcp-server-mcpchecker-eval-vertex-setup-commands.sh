#!/bin/bash
set -euo pipefail

# Copy the service account JSON into SHARED_DIR so it is accessible to the
# eval step, which runs in a separate container where /var/run/ocp-mcp is not
# mounted. GOOGLE_CLOUD_LOCATION, GOOGLE_CLOUD_PROJECT, and GEMINI_USE_VERTEX /
# ANTHROPIC_USE_VERTEX are passed via steps.env and flow automatically into all
# subsequent steps.
cp /var/run/ocp-mcp/service-account.json "${SHARED_DIR}/service-account.json"
chmod 0600 "${SHARED_DIR}/service-account.json"

cat >> "${SHARED_DIR}/mcpchecker-creds.env" <<EOF
export GOOGLE_APPLICATION_CREDENTIALS=${SHARED_DIR}/service-account.json
EOF
