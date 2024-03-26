#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

# loadBalancer.type: UserManaged enables the users to use their own LoadBalancer
# Ref: https://issues.redhat.com/browse/OPNET-305
# Note: keepalived and haproxy will not be deployed, coredns will

echo "Creating patch file to enable UserManaged loadbalancer: ${SHARED_DIR}/install-config.yaml"

cat > "${SHARED_DIR}/external_lb_patch_install_config.yaml" <<'EOF'
featureSet: TechPreviewNoUpgrade
platform:
  baremetal:
    loadBalancer:
      type: UserManaged
EOF

cp "$SHARED_DIR/external_vips.yaml" "$SHARED_DIR/vips.yaml"
