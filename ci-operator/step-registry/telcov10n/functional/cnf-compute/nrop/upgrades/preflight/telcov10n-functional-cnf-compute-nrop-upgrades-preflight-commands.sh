#!/bin/bash
set -euo pipefail
umask 077

if [[ "${UPGRADE_TYPE}" != "canary" ]]; then
    exit 0
fi

from_version="${VERSION}"
to_version="${TO_OCP_VERSION}"

deploy_version=$(python3 /eco-ci-cd/playbooks/compute/roles/ocp_upgrade/scripts/resolve-cincinnati-edge.py \
    eus-install --from "${from_version}" --to "${to_version}")
printf '%s' "${deploy_version}" > "${SHARED_DIR}/nrop-upgrades-deploy-version"
