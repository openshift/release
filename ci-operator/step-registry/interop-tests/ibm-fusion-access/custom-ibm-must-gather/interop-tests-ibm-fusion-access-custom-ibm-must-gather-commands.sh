#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: '🔍 Starting IBM Spectrum Scale must-gather collection...'

# Set default values from environment variables
FA__MUST_GATHER_IMAGE="${FA__MUST_GATHER_IMAGE:-pipeline:ibm-must-gather}"

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
  ibmEntitlementKeyPath="/var/run/secrets/ibm-entitlement-key"

  if [[ -f "${ibmEntitlementKeyPath}" ]]; then
    : 'Creating authfile for IBM registry...'
    jq -cnr --rawfile pwd "${ibmEntitlementKeyPath}" \
      '{ auths: { "icr.io": { auth: ("cp:\($pwd | rtrimstr("\n"))" | @base64) }}}' \
      > "${authFile}"
  else
    authFile=""
  fi
fi

mkdir -p /tmp/ibm-must-gather

oc adm must-gather --image="${FA__MUST_GATHER_IMAGE}" --dest-dir="/tmp/ibm-must-gather"

tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C /tmp ibm-must-gather

: 'IBM Spectrum Scale must-gather completed successfully'

true
