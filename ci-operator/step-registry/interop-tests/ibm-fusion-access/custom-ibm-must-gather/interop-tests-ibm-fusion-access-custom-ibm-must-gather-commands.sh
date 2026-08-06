#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔍 Starting IBM Spectrum Scale must-gather collection..."

# Set default values from environment variables
MUST_GATHER_IMAGE="${MUST_GATHER_IMAGE:-pipeline:ibm-must-gather}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

echo "Must-gather image: ${MUST_GATHER_IMAGE}"
echo "Artifact directory: ${ARTIFACT_DIR}"

# Check if we're using a pipeline image (pre-pulled) or external image
if [[ "$MUST_GATHER_IMAGE" == pipeline:* ]]; then
  echo "Using pre-pulled pipeline image: ${MUST_GATHER_IMAGE}"
  AUTHFILE=""
else
  echo "Using external image: ${MUST_GATHER_IMAGE}"
  # Create authfile for IBM registry
  AUTHFILE="/tmp/authfile"
  echo "Creating authfile for IBM registry..."

  # Get IBM entitlement key from standard location
  IBM_ENTITLEMENT_KEY=""
  IBM_ENTITLEMENT_KEY_PATH="/var/run/secrets/ibm-entitlement-key"

  # Check the standard credential location
  if [[ -f "$IBM_ENTITLEMENT_KEY_PATH" ]]; then
    echo "✅ IBM entitlement key found at: $IBM_ENTITLEMENT_KEY_PATH"
    IBM_ENTITLEMENT_KEY="$(cat "$IBM_ENTITLEMENT_KEY_PATH")"
  else
    echo "❌ IBM entitlement key not found at: $IBM_ENTITLEMENT_KEY_PATH"
  fi

  if [[ -n "$IBM_ENTITLEMENT_KEY" ]]; then
    echo "Creating authfile for IBM registry..."
    cat > "$AUTHFILE" <<EOF
{
  "auths": {
    "icr.io": {
      "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)"
    }
  }
}
EOF
    echo "Authfile created successfully"
  else
    echo "WARNING: IBM entitlement key not found, proceeding without authentication"
    AUTHFILE=""
  fi
fi

# Create artifact directory
mkdir -p "${ARTIFACT_DIR}/ibm-must-gather"

# Run must-gather with IBM image or fallback to standard must-gather
echo "Running must-gather..."

echo "Using pre-pulled IBM Spectrum Scale must-gather image..."
oc adm must-gather --image="${MUST_GATHER_IMAGE}" --dest-dir="${ARTIFACT_DIR}/ibm-must-gather"

# Archive results
echo "Archiving must-gather results..."
tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C "${ARTIFACT_DIR}" ibm-must-gather

# List artifacts
echo "Must-gather artifacts:"
ls -la "${ARTIFACT_DIR}/"

echo "IBM Spectrum Scale must-gather completed successfully"
