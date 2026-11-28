#!/bin/bash

set -euo pipefail

echo "************ hypershift-kubevirt localnet ip-echo (placeholder) ************"

# TODO: deploy an IP-echo service the guest cluster can reach, for EgressIP
# source-address verification.
#
# This is deliberately a no-op for now. The previous implementation lived inside
# hypershift-kubevirt-create and deployed a pod on the management cluster,
# attached to the guest's localnet through a NAD of its own. That cannot work:
#
#   * A second NetworkAttachmentDefinition naming an OVN network that already
#     has one is rejected by ovnkube-control-plane with "NAD <ns>/<name> CNI
#     config does not match that of network <physnet>", so pods referencing it
#     never receive an OVN annotation and sit in ContainerCreating until the
#     wait expires.
#   * Referencing the original NAD from another namespace does not help either:
#     OpenShift runs Multus with namespaceIsolation enabled, so a pod outside
#     globalNamespaces may not refer to a NAD in another namespace.
#
# The agreed direction is to run the echo service on the bastion instead, which
# removes the NAD, the namespace, PodSecurity and scheduling entirely, and is
# already the established pattern for EgressIP validation elsewhere in this
# registry — see openshift-qe/egress-ip-bastion-echo-deploy, which runs:
#
#   podman run -d --name external-agnhost -p 9095:8080 \
#     registry.k8s.io/e2e-test-images/agnhost:2.40 netexec --http-port=8080
#
# and exposes /clientip. That ref discovers the bastion from
# $SHARED_DIR/bastion_public_address and opens an AWS security group, so it
# needs generalising for baremetalds, where the bastion comes from
# $SHARED_DIR/packet-conf.sh (SSHOPTS, IP) and no security group exists.
#
# Reachability is already satisfied on the current topologies: the bastion holds
# the gateway address on each guest segment (192.168.111.1 for multinet,
# 192.168.221.1 for secondary-localnet, both verified reachable from a guest).
# The VLAN workflows will additionally need a VLAN subinterface on the bastion
# before the container is started.
#
# Still to confirm before building this out: that EgressIP SNAT applies to
# traffic destined for the bastion address. It should — the bastion is not a
# guest node IP and is outside the pod and service CIDRs, which is what OVN's
# priority-102 policy exempts — but it is worth one measured curl from a guest
# pod with an EgressIP assigned rather than assuming.
#
# Revisit when the VLAN workflows land, so the same ref covers multinet,
# secondary-localnet and the VLAN topologies.

echo "No-op: ip-echo deployment is not implemented yet."
echo "See the comments in this script and the TODO in the ref documentation."
