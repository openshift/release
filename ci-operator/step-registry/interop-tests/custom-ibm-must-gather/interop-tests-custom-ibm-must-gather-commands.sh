#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔍 Starting IBM Spectrum Scale must-gather collection..."

# Set default values from environment variables
MUST_GATHER_IMAGE="${MUST_GATHER_IMAGE:-icr.io/cpopen/ibm-spectrum-scale-must-gather:latest}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

echo "Must-gather image: ${MUST_GATHER_IMAGE}"
echo "Artifact directory: ${ARTIFACT_DIR}"

# Create authfile for IBM registry
AUTHFILE="/tmp/authfile"
echo "Creating authfile for IBM registry..."

# Get IBM entitlement key from credentials
if [[ -f "/tmp/secrets/ibm-entitlement-credentials/ibm-entitlement-key" ]]; then
  echo "IBM entitlement key found, creating authfile..."
  cat > "$AUTHFILE" <<EOF
{
  "auths": {
    "icr.io": {
      "auth": "$(echo -n "cp:$(cat /tmp/secrets/ibm-entitlement-credentials/ibm-entitlement-key)" | base64 -w 0)"
    }
  }
}
EOF
  echo "Authfile created successfully"
else
  echo "WARNING: IBM entitlement key not found, proceeding without authentication"
  AUTHFILE=""
fi

# Create artifact directory
mkdir -p "${ARTIFACT_DIR}/ibm-must-gather"

# Run must-gather with IBM image
echo "Running IBM Spectrum Scale must-gather..."
if [[ -n "$AUTHFILE" ]]; then
  oc adm must-gather --image="${MUST_GATHER_IMAGE}" --authfile="$AUTHFILE" --dest-dir="${ARTIFACT_DIR}/ibm-must-gather"
else
  oc adm must-gather --image="${MUST_GATHER_IMAGE}" --dest-dir="${ARTIFACT_DIR}/ibm-must-gather"
fi

# Archive results
echo "Archiving must-gather results..."
tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C "${ARTIFACT_DIR}" ibm-must-gather

# List artifacts
echo "Must-gather artifacts:"
ls -la "${ARTIFACT_DIR}/"

echo "IBM Spectrum Scale must-gather completed successfully"
