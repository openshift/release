#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Print tenancy from vault"

cat /var/run/oci-secret-tenancy/tenancy_ocid

echo "Print compartment from vault"

cat /var/run/oci-secret-compartment/compartment

