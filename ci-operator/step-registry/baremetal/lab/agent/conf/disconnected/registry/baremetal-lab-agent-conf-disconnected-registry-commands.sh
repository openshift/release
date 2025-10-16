#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

buildfarm_secrets="/var/run/vault/secrets/.dockerconfigjson"

pull_secret=$(<"${buildfarm_secrets}")

cp $buildfarm_secrets $ARTIFACT_DIR/pull_secrets

# Add buildfarm secrets if the mirror registry secrets are not available.
if [ ! -f "${SHARED_DIR}/pull_secret_ca.yaml.patch" ]; then
  yq -i 'del(.pullSecret)' "${SHARED_DIR}/install-config.yaml"
  cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
pullSecret: >
  ${pull_secret}
EOF
fi