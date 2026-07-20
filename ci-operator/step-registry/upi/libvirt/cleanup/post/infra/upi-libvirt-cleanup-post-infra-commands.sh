#!/bin/bash
# Infra-cluster cleanup wrapper. CLUSTER_ROLE=infra is injected by the ref's
# env declaration, so when upi-libvirt-cleanup-post-commands.sh runs it will
# automatically redirect LEASED_RESOURCE → LEASED_RESOURCE_INFRA.
# ci-operator copies all step scripts into the same flat directory on the pod,
# so we can call the parent script directly by name.
exec upi-libvirt-cleanup-post-commands.sh
