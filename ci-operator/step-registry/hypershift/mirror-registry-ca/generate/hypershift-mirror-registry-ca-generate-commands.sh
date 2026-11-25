#!/bin/bash

set -euo pipefail

# The tests deploy the mirror registry later, but the management cluster nodes
# and the HyperShift operator must already trust it. Generate the CA here and
# hand both halves to the tests through SHARED_DIR.
# The file names are a contract with openshift/hypershift: the e2e v2 tests read
# exactly these names (test/e2e/v2/lifecycle/mirrorregistry.go), and workflows
# pass the certificate name to hypershift-setup-nested-management-cluster
# (HYPERSHIFT_MGMT_ADDITIONAL_TRUST_BUNDLE). Change them in both repositories.
cert="${SHARED_DIR}/mirror-registry-ho-ca.crt"
key="${SHARED_DIR}/mirror-registry-ho-ca.key"
# The step pod is discarded afterwards, so the temporary copy needs no cleanup.
workdir="$(mktemp -d)"

openssl req -x509 -newkey rsa:4096 -nodes -days 7 \
  -keyout "${workdir}/ca.key" -out "${workdir}/ca.crt" \
  -subj "/OU=hypershift-e2e-mirror-registry/CN=hypershift-e2e-mirror-registry-ho-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

cp "${workdir}/ca.crt" "${cert}"
cp "${workdir}/ca.key" "${key}"

echo "Wrote mirror registry CA to ${cert} and ${key}"
openssl x509 -in "${cert}" -noout -subject -enddate -fingerprint -sha256
