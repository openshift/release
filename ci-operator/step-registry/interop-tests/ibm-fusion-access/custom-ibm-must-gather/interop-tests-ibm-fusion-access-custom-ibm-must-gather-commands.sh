#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: '🔍 Starting IBM Spectrum Scale must-gather collection...'

# Set default values from environment variables
FA__MUST_GATHER_IMAGE="${FA__MUST_GATHER_IMAGE:-pipeline:ibm-must-gather}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

: "Must-gather image: ${FA__MUST_GATHER_IMAGE}"
: "Artifact directory: ${ARTIFACT_DIR}"

# Check if we're using a pipeline image (pre-pulled) or external image
if [[ "$FA__MUST_GATHER_IMAGE" == pipeline:* ]]; then
  : "Using pre-pulled pipeline image: ${FA__MUST_GATHER_IMAGE}"
  authFile=""
else
  : "Using external image: ${FA__MUST_GATHER_IMAGE}"
  # Create authfile for IBM registry
  authFile="/tmp/authfile"
  : 'Creating authfile for IBM registry...'

  # Disable tracing due to credential handling
  set +x

  # Get IBM entitlement key from standard location
  IBM_ENTITLEMENT_KEY=""
  IBM_ENTITLEMENT_KEY_PATH="/var/run/secrets/ibm-entitlement-key"

  # Check the standard credential location
  if [[ -f "$IBM_ENTITLEMENT_KEY_PATH" ]]; then
    IBM_ENTITLEMENT_KEY="$(cat "$IBM_ENTITLEMENT_KEY_PATH")"
  fi

  if [[ -n "$IBM_ENTITLEMENT_KEY" ]]; then
    cat > "$authFile" <<EOF
{
  "auths": {
    "icr.io": {
      "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)"
    }
  }
}
EOF
  else
    authFile=""
  fi

  # Re-enable tracing
  set -x
fi

mkdir -p /tmp/ibm-must-gather

oc adm must-gather --image="${FA__MUST_GATHER_IMAGE}" --dest-dir="/tmp/ibm-must-gather"

tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C /tmp ibm-must-gather

: 'IBM Spectrum Scale must-gather completed successfully'

