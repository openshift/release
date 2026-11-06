#!/bin/bash

set -euo pipefail

# The tests deploy the mirror registry later, but the management cluster nodes
# and the HyperShift operator must already trust it. Generate the CA here and
# hand both halves to the tests through SHARED_DIR.
cert="${SHARED_DIR}/${MIRROR_REGISTRY_CA_FILE_PREFIX}.crt"
key="${SHARED_DIR}/${MIRROR_REGISTRY_CA_FILE_PREFIX}.key"
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
