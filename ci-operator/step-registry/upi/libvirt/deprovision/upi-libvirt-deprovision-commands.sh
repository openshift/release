#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LIBVIRT_DOMAIN_NAME_SUFFIX="libvirt-s390x-amd64-0-0-ci"

export LIBVIRT_DEFAULT_URI="qemu+tcp://lnxocp10:16509/system"

DOMAINS_TO_DESTROY=$(virsh list --all --name | grep ${LIBVIRT_DOMAIN_NAME_SUFFIX})
for domain in $DOMAINS_TO_DESTROY; do
    virsh undefine "${domain}"
    virsh destroy "${domain}"
    virsh vol-delete --pool images "${domain}".qcow2
done

export LIBVIRT_DEFAULT_URI="qemu+tcp://xkvmocp04:16510/system"

DOMAINS_TO_DESTROY=$(virsh list --all --name | grep ${LIBVIRT_DOMAIN_NAME_SUFFIX})
for domain in $DOMAINS_TO_DESTROY; do
    virsh undefine "${domain}"
    virsh destroy "${domain}"
    virsh vol-delete --pool default "${domain}".qcow2
done