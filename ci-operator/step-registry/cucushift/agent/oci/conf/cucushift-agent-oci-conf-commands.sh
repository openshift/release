#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

RENDEZVOUS_IP=$( [ "${ISCSI:-false}" == "true" ] && echo "10.0.32.20" || echo "10.0.16.20" )
echo "${RENDEZVOUS_IP}" >"${SHARED_DIR}"/node-zero-ip.txt

cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
EOF
