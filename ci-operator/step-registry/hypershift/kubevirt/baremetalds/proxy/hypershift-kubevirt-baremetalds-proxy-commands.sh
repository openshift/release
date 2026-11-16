#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


source "${SHARED_DIR}/packet-conf.sh" && scp "${SSHOPTS[@]}" "${SHARED_DIR}/nested_kubeconfig" "root@${IP}:nested_kubeconfig"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
API_SERVER=$(yq -r '.clusters[0].cluster.server' nested_kubeconfig | sed -E 's#^https?://([^:/]+).*#\1#')
[[ -n "${API_SERVER}" ]] || { echo "Guest API server URL is missing" >&2; exit 1; }
sed -i "1 s|$| $API_SERVER|" $HOME/squid.conf

sudo setenforce 0
sudo podman stop -t 120 external-squid
sudo podman run -d --rm \
     --net host \
     --volume $HOME/squid.conf:/etc/squid/squid.conf \
     --name external-squid \
     --dns 127.0.0.1 \
     quay.io/openshifttest/squid-proxy:multiarch
EOF

echo "Adding proxy-url in kubeconfig"
sed -i "/- cluster/ a\    proxy-url: http://$IP:8213/" "${SHARED_DIR}"/nested_kubeconfig
if [[ -f "${SHARED_DIR}/ofcir-role" ]]; then
    role="$(<"${SHARED_DIR}/ofcir-role")"
    if [[ "${role}" == source || "${role}" == target ]]; then
        cp "${SHARED_DIR}/nested_kubeconfig" "${SHARED_DIR}/nested_kubeconfig_${role}"
    fi
fi
