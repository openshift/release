#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'mirror_ran_test_images' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Mirroring RAN test images for spoke: ${SPOKE_CLUSTER}, hub: ${HUB_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER:-dummy-spoke}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local DEBUG_FLAG="-vv"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        DEBUG_FLAG="-vvv"
    fi

    if [[ -z "${RAN_IMAGES:-}" ]]; then
        echo "WARNING: RAN_IMAGES is empty. No images to mirror."
        echo "Set ran_images in INFRA_SETTINGS in the CI config. Example:"
        echo '  {"mirror_ran_test_images": {"ran_images": {"images": ["quay.io/telcov10n-ci/oslat:latest", ...]}}}'
        exit 1
    fi

    local images_file="/tmp/mirror-images-extra-vars.json"
    python3 -c "
import json, sys
raw = json.loads(sys.argv[1])
source_images = raw.get('images', [])
result = []
for src in source_images:
    name_tag = src.rsplit('/', 1)[-1]
    result.append({'source': src, 'dest': 'ran-test/' + name_tag})
with open(sys.argv[2], 'w') as f:
    json.dump({'images': result}, f)
print(f'Mirroring {len(result)} image(s)')
" "${RAN_IMAGES}" "${images_file}"

    ansible-playbook ./playbooks/telco-kpis/mirror-images.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "@${images_file}" \
        -e "registry_host=disconnected.registry.local" \
        ${DEBUG_FLAG}

    echo "RAN test image mirroring completed for hub: ${HUB_CLUSTER}"
}

main
