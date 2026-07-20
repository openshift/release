#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'deploy_sno_hub' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Deploying SNO hub cluster: ${HUB_CLUSTER}"

    # Hub IS the OCP cluster being deployed — pass as both spoke and hub args
    setup_ansible_inventory "${HUB_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    # Determine release: lockdown > explicit image > version
    local release=""
    if [[ -n "${HUB_LOCKDOWN_URI:-}" ]]; then
        echo "Resolving OCP release from hub lockdown: ${HUB_LOCKDOWN_URI}"
        ansible-playbook ./playbooks/telco-kpis/download-lockdown.yml \
            -i ./inventories/ocp-deployment/build-inventory.py \
            -e "lockdown_uri=${HUB_LOCKDOWN_URI}" \
            -e "lockdown_local_path=/tmp/hub-lockdown.json" \
            ${DEBUG_FLAG}
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

    ansible-playbook ./playbooks/deploy-ocp-sno.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e release="${release}" \
        -e cluster_name="${HUB_CLUSTER}" \
        -e disconnected=true \
        ${DEBUG_FLAG}

    echo "SNO hub deployment completed: ${HUB_CLUSTER}"
}

main
