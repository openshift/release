#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

case "${TLS_PROFILE_TYPE}" in
Modern|Intermediate|Old) ;;
*)
  echo "Unsupported TLS_PROFILE_TYPE '${TLS_PROFILE_TYPE}'; expected Modern, Intermediate, or Old"
  exit 1
  ;;
esac

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-tls-profile.yaml"

cat > "${PATCH}" << EOF
tlsProfileType: ${TLS_PROFILE_TYPE}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
rm -f "${PATCH}"

observed_profile=$(yq-go r "${CONFIG}" tlsProfileType)
if [[ "${observed_profile}" != "${TLS_PROFILE_TYPE}" ]]; then
  echo "Expected tlsProfileType '${TLS_PROFILE_TYPE}' in '${CONFIG}', found '${observed_profile}'"
  exit 1
fi

echo "Set tlsProfileType to '${TLS_PROFILE_TYPE}' in '${CONFIG}'."
