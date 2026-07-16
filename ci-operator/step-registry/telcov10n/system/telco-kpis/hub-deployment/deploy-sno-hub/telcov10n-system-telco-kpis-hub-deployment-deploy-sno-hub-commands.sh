#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'deploy_sno_hub' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"

main() {
    echo "Deploying SNO hub cluster: ${HUB_CLUSTER}"

    # Hub IS the OCP cluster being deployed — pass as both spoke and hub args
    setup_ansible_inventory "${HUB_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    # Determine release: lockdown > explicit image > version
    local release=""
    if [[ -n "${HUB_LOCKDOWN_URI:-}" ]]; then
        echo "Resolving OCP release from hub lockdown: ${HUB_LOCKDOWN_URI}"
        download_lockdown_json "${HUB_LOCKDOWN_URI}" /tmp/hub-lockdown.json
        release=$(python3 -c "
import json, sys
data = json.load(open('/tmp/hub-lockdown.json'))
ps = data['hub']['ocp']['pull_spec']
print(ps['tag'] if isinstance(ps, dict) else ps)
")
        echo "OCP release from lockdown: ${release}"
    elif [[ -n "${OCP_RELEASE_IMAGE:-}" ]]; then
        release="${OCP_RELEASE_IMAGE}"
        echo "OCP release from explicit image: ${release}"
    else
        release="${VERSION}"
        echo "OCP release from version: ${release}"
    fi

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    ansible-playbook ./playbooks/deploy-ocp-sno.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e release="${release}" \
        -e cluster_name="${HUB_CLUSTER}" \
        -e disconnected=true \
        ${DEBUG_FLAG}

    echo "SNO hub deployment completed: ${HUB_CLUSTER}"
}

main
