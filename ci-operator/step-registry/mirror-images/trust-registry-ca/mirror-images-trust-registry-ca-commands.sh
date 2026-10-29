#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This step patches the live cluster under test, which on a disconnected
# install is only reachable through the bastion's egress proxy — without
# this, `oc` can't even resolve the API server hostname. Same pattern used
# by every other step in this workflow that talks to the cluster post-install
# (e.g. disable-default-sources in ipi-aws-pre-disconnected).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist, skipping mirror registry CA trust configuration..."
    exit 0
fi
if [ ! -f "${SHARED_DIR}/additional_trust_bundle" ]; then
    echo "File ${SHARED_DIR}/additional_trust_bundle does not exist, skipping mirror registry CA trust configuration..."
    exit 0
fi

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

# `install-config.yaml`'s `additionalTrustBundlePolicy: Always` (set by
# ipi-conf-additional-ca-trust-policy) only adds the CA to the *nodes'*
# trusted certificate store (see the AdditionalTrustBundlePolicy doc comment
# in openshift/installer's pkg/types/installconfig.go) — it does not
# propagate to any cluster-scoped config object. In-cluster consumers that
# don't run on the host (the image registry's image-stream import
# controller, the build controller's git/image fetch client) instead read
# image.config.openshift.io/cluster's spec.additionalTrustedCA, which must
# be set explicitly. This is the documented procedure for disconnected
# mirror registries with self-signed certs, see:
# https://docs.openshift.com/container-platform/4.18/post_installation_configuration/post-install-image-config.html
#
# The ConfigMap key uses the registry host with the port-separating colon
# replaced by two dots (host:port -> host..port); this is the exact
# convention documented above and used by every other consumer of this
# pattern already in this registry (e.g. set-sample-operator-disconnected,
# ipi-openstack-pre-disconnected).
CONFIGMAP_KEY="${MIRROR_REGISTRY_HOST/:/..}"

oc create configmap registry-config \
    --from-file="${CONFIGMAP_KEY}=${SHARED_DIR}/additional_trust_bundle" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -

oc patch image.config.openshift.io/cluster --type=merge \
    --patch '{"spec":{"additionalTrustedCA":{"name":"registry-config"}}}'

echo "Patched image.config.openshift.io/cluster to trust ${MIRROR_REGISTRY_HOST} via the registry-config ConfigMap"
