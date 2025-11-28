#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔍 Starting IBM Spectrum Scale must-gather collection..."

# Set default values from environment variables
FA__MUST_GATHER_IMAGE="${FA__MUST_GATHER_IMAGE:-pipeline:ibm-must-gather}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

echo "Must-gather image: ${FA__MUST_GATHER_IMAGE}"
echo "Artifact directory: ${ARTIFACT_DIR}"

# Check if we're using a pipeline image (pre-pulled) or external image
if [[ "$FA__MUST_GATHER_IMAGE" == pipeline:* ]]; then
  echo "Using pre-pulled pipeline image: ${FA__MUST_GATHER_IMAGE}"
  AUTHFILE=""
else
  echo "Using external image: ${FA__MUST_GATHER_IMAGE}"
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

# Run must-gather with IBM image or fallback to standard must-gather
echo "Running must-gather..."

# Use /tmp for intermediate files to avoid bloating ARTIFACT_DIR
MUST_GATHER_TMP_DIR="/tmp/ibm-must-gather"
mkdir -p "${MUST_GATHER_TMP_DIR}"

echo "Using pre-pulled IBM Spectrum Scale must-gather image..."
oc adm must-gather --image="${FA__MUST_GATHER_IMAGE}" --dest-dir="${MUST_GATHER_TMP_DIR}"

# Archive results to ARTIFACT_DIR (only final archive, not intermediate files)
echo "Archiving must-gather results..."
tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C /tmp ibm-must-gather

# List artifacts
echo "Must-gather artifacts:"
ls -la "${ARTIFACT_DIR}/ibm-must-gather.tar.gz"

echo "IBM Spectrum Scale must-gather completed successfully"
