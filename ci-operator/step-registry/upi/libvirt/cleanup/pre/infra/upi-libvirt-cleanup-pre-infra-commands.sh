#!/bin/bash
# Wrapper that runs the standard upi-libvirt-cleanup-pre logic but against the
# infra cluster lease (LEASED_RESOURCE_INFRA) instead of the mgmt lease.
export LEASED_RESOURCE="${LEASED_RESOURCE_INFRA}"
exec upi-libvirt-cleanup-pre-commands.sh
