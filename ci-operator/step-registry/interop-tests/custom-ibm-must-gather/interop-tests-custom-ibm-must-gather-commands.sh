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
IBM_ENTITLEMENT_KEY=""

# Check common credential locations
for path in \
  "/tmp/secrets/ibm-entitlement-credentials/ibm-entitlement-key" \
  "/var/run/secrets/ibm-entitlement-key" \
  "/secrets/ibm-entitlement-key" \
  "/tmp/ibm-entitlement-key"; do
  if [[ -f "$path" ]]; then
    echo "IBM entitlement key found at: $path"
    IBM_ENTITLEMENT_KEY="$(cat "$path")"
    break
  fi
done

# Check if credentials are available as environment variable
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
  echo "IBM entitlement key found in environment variable"
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

# Create artifact directory
mkdir -p "${ARTIFACT_DIR}/ibm-must-gather"

# Run must-gather with IBM image or fallback to standard must-gather
echo "Running must-gather..."
if [[ -n "$AUTHFILE" ]]; then
  echo "Using IBM Spectrum Scale must-gather with authentication..."
  oc adm must-gather --image="${MUST_GATHER_IMAGE}" --authfile="$AUTHFILE" --dest-dir="${ARTIFACT_DIR}/ibm-must-gather"
else
  echo "IBM entitlement key not available, falling back to standard OpenShift must-gather..."
  echo "This is expected in rehearsal runs without IBM credentials"
  oc adm must-gather --dest-dir="${ARTIFACT_DIR}/ibm-must-gather"
fi

# Archive results
echo "Archiving must-gather results..."
tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C "${ARTIFACT_DIR}" ibm-must-gather

# List artifacts
echo "Must-gather artifacts:"
ls -la "${ARTIFACT_DIR}/"

echo "IBM Spectrum Scale must-gather completed successfully"
