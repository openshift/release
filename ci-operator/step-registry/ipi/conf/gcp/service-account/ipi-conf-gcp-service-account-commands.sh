#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
if test -z "${GOOGLE_PROJECT_ID}"; then
  echo "ERROR: Failed to get GCP project id, abort. " && exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/service-account.yaml.patch"

if [ -n "${COMPUTE_SERVICE_ACCOUNT}" ]; then
  if [[ "${COMPUTE_SERVICE_ACCOUNT}" =~ @ ]]; then
    sa_email="${COMPUTE_SERVICE_ACCOUNT}"
  else
    sa_email="${COMPUTE_SERVICE_ACCOUNT}@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"
  fi
  cat > "${PATCH}" << EOF
compute:
- platform:
    gcp:
      serviceAccount: ${sa_email}
EOF
fi

if [ -n "${CONTROL_PLANE_SERVICE_ACCOUNT}" ]; then
  if [[ "${CONTROL_PLANE_SERVICE_ACCOUNT}" =~ @ ]]; then
    sa_email="${CONTROL_PLANE_SERVICE_ACCOUNT}"
  else
    sa_email="${CONTROL_PLANE_SERVICE_ACCOUNT}@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"
  fi
  cat >> "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      serviceAccount: ${sa_email}
EOF
fi

if [ -n "${DEFAULT_MACHINE_SERVICE_ACCOUNT}" ]; then
  if [[ "${DEFAULT_MACHINE_SERVICE_ACCOUNT}" =~ @ ]]; then
    sa_email="${DEFAULT_MACHINE_SERVICE_ACCOUNT}"
  else
    sa_email="${DEFAULT_MACHINE_SERVICE_ACCOUNT}@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"
  fi
  cat >> "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      serviceAccount: ${sa_email}
EOF
fi

if [ -s "${PATCH}" ]; then
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  yq-go r "${CONFIG}" compute
  yq-go r "${CONFIG}" controlPlane
  yq-go r "${CONFIG}" platform

  rm "${PATCH}"
fi