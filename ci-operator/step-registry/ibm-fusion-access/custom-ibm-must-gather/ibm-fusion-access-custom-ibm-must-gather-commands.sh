#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Starting IBM Spectrum Scale must-gather collection...'

FA__MUST_GATHER_IMAGE="${FA__MUST_GATHER_IMAGE:-pipeline:ibm-must-gather}"

: "Must-gather image: ${FA__MUST_GATHER_IMAGE}"
: "Artifact directory: ${ARTIFACT_DIR}"

if [[ "$FA__MUST_GATHER_IMAGE" == pipeline:* ]]; then
  : "Using pre-pulled pipeline image: ${FA__MUST_GATHER_IMAGE}"
  authFile=""
else
  : "Using external image: ${FA__MUST_GATHER_IMAGE}"
  authFile="/tmp/authfile"

  ibmEntitlementKeyPath="/var/run/secrets/ibm-entitlement-key"

  if [[ -f "${ibmEntitlementKeyPath}" ]]; then
    : "IBM entitlement key found at: ${ibmEntitlementKeyPath}"
    : 'Creating authfile for IBM registry...'
    jq -cnr --rawfile pwd "${ibmEntitlementKeyPath}" \
      '{ auths: { "icr.io": { auth: ("cp:\($pwd | rtrimstr("\n"))" | @base64) }}}' \
      > "${authFile}"
    : 'Authfile created successfully'
  else
    : "IBM entitlement key not found at: ${ibmEntitlementKeyPath}"
    : 'WARNING: proceeding without authentication'
    authFile=""
  fi
fi

: 'Running must-gather...'

mustGatherTmpDir="/tmp/ibm-must-gather"
mkdir -p "${mustGatherTmpDir}"

oc adm must-gather --image="${FA__MUST_GATHER_IMAGE}" --dest-dir="${mustGatherTmpDir}"

: 'Archiving must-gather results...'
tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C /tmp ibm-must-gather

ls -la "${ARTIFACT_DIR}/ibm-must-gather.tar.gz"

: 'IBM Spectrum Scale must-gather completed successfully'

true
