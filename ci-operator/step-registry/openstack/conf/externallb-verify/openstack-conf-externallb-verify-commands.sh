#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE:-}" != *"externallb"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not containing externallb."
    exit 0
fi

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

dns_records_type="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.openstack.dnsRecordsType}')"
if [[ "${dns_records_type}" != "External" ]]; then
    echo "ERROR: expected dnsRecordsType=External, got '${dns_records_type}'"
    exit 1
fi
echo "dnsRecordsType is External"

load_balancer_type="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.openstack.loadBalancer.type}')"
if [[ "${load_balancer_type}" != "UserManaged" ]]; then
    echo "ERROR: expected loadBalancer.type=UserManaged, got '${load_balancer_type}'"
    exit 1
fi
echo "loadBalancer.type is UserManaged"
