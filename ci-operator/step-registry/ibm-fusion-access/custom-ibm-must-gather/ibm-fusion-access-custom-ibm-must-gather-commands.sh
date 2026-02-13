#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Starting IBM Spectrum Scale must-gather collection...'

FA__MUST_GATHER_IMAGE="${FA__MUST_GATHER_IMAGE:-pipeline:ibm-must-gather}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

: "Must-gather image: ${FA__MUST_GATHER_IMAGE}"
: "Artifact directory: ${ARTIFACT_DIR}"

if [[ "$FA__MUST_GATHER_IMAGE" == pipeline:* ]]; then
  : "Using pre-pulled pipeline image: ${FA__MUST_GATHER_IMAGE}"
  AUTHFILE=""
else
  : "Using external image: ${FA__MUST_GATHER_IMAGE}"
  AUTHFILE="/tmp/authfile"

  IBM_ENTITLEMENT_KEY=""
  IBM_ENTITLEMENT_KEY_PATH="/var/run/secrets/ibm-entitlement-key"

  if [[ -f "$IBM_ENTITLEMENT_KEY_PATH" ]]; then
    set +x
    IBM_ENTITLEMENT_KEY="$(cat "$IBM_ENTITLEMENT_KEY_PATH")"
    set -x
    : "IBM entitlement key found at: $IBM_ENTITLEMENT_KEY_PATH"
  else
    : "IBM entitlement key not found at: $IBM_ENTITLEMENT_KEY_PATH"
  fi

  if [[ -n "$IBM_ENTITLEMENT_KEY" ]]; then
    : 'Creating authfile for IBM registry...'
    set +x
    cat > "$AUTHFILE" <<EOF
{
  "auths": {
    "icr.io": {
      "auth": "$(echo -n "cp:${IBM_ENTITLEMENT_KEY}" | base64 -w 0)"
    }
  }
}
EOF
    set -x
    : 'Authfile created successfully'
  else
    : 'WARNING: IBM entitlement key not found, proceeding without authentication'
    AUTHFILE=""
  fi
fi

: 'Running must-gather...'

MUST_GATHER_TMP_DIR="/tmp/ibm-must-gather"
mkdir -p "${MUST_GATHER_TMP_DIR}"

oc adm must-gather --image="${FA__MUST_GATHER_IMAGE}" --dest-dir="${MUST_GATHER_TMP_DIR}"

: 'Archiving must-gather results...'
tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C /tmp ibm-must-gather

ls -la "${ARTIFACT_DIR}/ibm-must-gather.tar.gz"

: 'IBM Spectrum Scale must-gather completed successfully'
