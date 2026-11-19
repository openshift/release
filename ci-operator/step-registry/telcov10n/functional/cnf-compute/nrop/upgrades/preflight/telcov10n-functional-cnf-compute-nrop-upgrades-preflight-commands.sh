#!/bin/bash
set -euo pipefail
umask 077

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
    echo "Skipping the NROP upgrade."
    exit 0
fi

from_version=$(printf '%s' "${FROM_OCP_VERSION}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
to_version=$(printf '%s' "${TO_OCP_VERSION}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
deploy_version="${from_version}"
if [[ "${UPGRADE_TYPE}" == "canary" ]] && [[ "${from_version}" != */* ]]; then
    from_minor="${from_version}"
    if [[ "${from_version}" =~ ([0-9]+\.[0-9]+) ]]; then
        from_minor="${BASH_REMATCH[1]}"
    fi
    to_minor="${to_version%%@*}"
    to_minor="${to_minor##*/}"
    to_minor="${to_minor##*:}"
    if [[ "${to_minor}" =~ ([0-9]+\.[0-9]+) ]]; then
        to_minor="${BASH_REMATCH[1]}"
    fi
    deploy_version=$(python3 /eco-ci-cd/playbooks/compute/roles/ocp_upgrade/scripts/resolve-cincinnati-edge.py \
        eus-install --from "${from_minor}" --to "${to_minor}")
fi
printf '%s' "${deploy_version}" > "${SHARED_DIR}/nrop-upgrades-deploy-version"
