#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

if [ "${BMC_VERIFY_CA:-false}" != "true" ]; then
  echo "BMC Verify CA is not enabled. Skipping..."
  exit 0
fi

# Configure proxy if available
if [[ -f "${CLUSTER_PROFILE_DIR}/proxy" ]]; then
    proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
    export HTTP_PROXY=${proxy}
    export HTTPS_PROXY=${proxy}
    export NO_PROXY="localhost,127.0.0.1"
    echo "Using proxy: ${proxy}"
fi

echo "=== BMC Certificate Generation and Upload ==="
echo ""

# Certificate directory - store directly in SHARED_DIR (no subdirectories)
CERT_DIR="${SHARED_DIR}"

CA_CERT="${CERT_DIR}/bmc-ca.crt"
CA_KEY="${CERT_DIR}/bmc-ca.key"

# Step 1: Generate CA certificate
echo "[1/4] Generating BMC CA Certificate..."
openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null
openssl req -new -x509 -key "${CA_KEY}" -out "${CA_CERT}" -days 3650 \
  -subj "/C=US/ST=NC/L=Raleigh/O=Red Hat/OU=OpenShift QE/CN=BMC Certificate Authority" 2>/dev/null
echo "  ✓ CA certificate generated"
echo ""

# Step 2: Generate certificates for each BMC
echo "[2/4] Generating BMC certificates..."

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "$SHARED_DIR/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')

  # Only process HPE/HP servers
  if [[ "${vendor:-}" != "hp" ]] && [[ "${vendor:-}" != "hpe" ]]; then
    echo "  Skipping ${name} (vendor: ${vendor:-unknown}, only HP/HPE supported)"
    continue
  fi

  CERT_NAME="ilo-${name}"
  echo "  Generating certificate for ${name} (vendor: ${vendor}, ${bmc_address})..."

  # Generate private key
  openssl genrsa -out "${CERT_DIR}/${CERT_NAME}.key" 2048 2>/dev/null

  # Create OpenSSL config with SAN
  cat > "${CERT_DIR}/${CERT_NAME}.conf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=US
ST=NC
L=Raleigh
O=Red Hat
OU=OpenShift QE
CN=${name}

[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${name}
DNS.2 = ilo-${name}
IP.1 = ${bmc_address}
EOF

  # Generate CSR
  openssl req -new -key "${CERT_DIR}/${CERT_NAME}.key" \
    -out "${CERT_DIR}/${CERT_NAME}.csr" \
    -config "${CERT_DIR}/${CERT_NAME}.conf" 2>/dev/null

  # Sign certificate with CA (valid for 2 years)
  openssl x509 -req -in "${CERT_DIR}/${CERT_NAME}.csr" \
    -CA "${CA_CERT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${CERT_DIR}/${CERT_NAME}.crt" -days 730 \
    -extensions v3_req -extfile "${CERT_DIR}/${CERT_NAME}.conf" 2>/dev/null

  # Create combined PEM file for upload
  cat "${CERT_DIR}/${CERT_NAME}.crt" "${CERT_DIR}/${CERT_NAME}.key" > "${CERT_DIR}/${CERT_NAME}-combined.pem"

  echo "    ✓ Certificate created: ${CERT_NAME}"
done

echo ""
echo "  ✓ All BMC certificates generated"
echo ""

# Step 3: Upload certificates to BMCs
echo "[3/4] Uploading certificates to BMC controllers..."

SUCCESS_COUNT=0
FAIL_COUNT=0

# Function to upload certificate via Redfish API
upload_bmc_cert() {
  local BMC_IP=$1
  local CERT_FILE=$2
  local USER=$3
  local PASS=$4
  local BMC_NAME=$5

  # Check if cert file exists
  if [[ ! -f "${CERT_FILE}" ]]; then
    echo "    ✗ Certificate file not found: ${CERT_FILE}"
    return 1
  fi

  # Combine cert and key, escape for JSON
  local COMBINED
  COMBINED=$(cat "$CERT_FILE" | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')

  # Upload certificate via HPE iLO Redfish endpoint
  local CERT_UPLOAD_URL="https://${BMC_IP}/redfish/v1/Managers/1/SecurityService/HttpsCert/Actions/HpeHttpsCert.ImportCertificate"
  local RESPONSE
  RESPONSE=$(curl -sk -w "\nHTTP_CODE:%{http_code}" --connect-timeout 10 \
    -u "${USER}:${PASS}" \
    -H "Content-Type: application/json" \
    -X POST \
    "${CERT_UPLOAD_URL}" \
    -d "{\"Certificate\":\"${COMBINED}\"}" 2>&1 || true)

  local HTTP_CODE
  HTTP_CODE=$(echo "$RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | tail -1 | cut -d: -f2 || echo "000")

  if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "202" ]] || [[ "$HTTP_CODE" == "204" ]]; then
    echo "    ✓ Certificate uploaded to ${BMC_NAME}"
    return 0
  else
    echo "    ✗ Failed to upload certificate to ${BMC_NAME} (HTTP ${HTTP_CODE})"
    if [[ "$HTTP_CODE" == "000" ]]; then
      echo "       Connection error"
    fi
    return 1
  fi
}

# Upload to each BMC
for bmhost in $(yq e -o=j -I=0 '.[]' "$SHARED_DIR/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')

  # Only upload to HPE/HP servers
  if [[ "${vendor:-}" != "hp" ]] && [[ "${vendor:-}" != "hpe" ]]; then
    echo "  Skipping ${name} (vendor: ${vendor:-unknown}, only HP/HPE supported)"
    continue
  fi

  CERT_NAME="ilo-${name}"
  CERT_FILE="${CERT_DIR}/${CERT_NAME}-combined.pem"

  echo "  Uploading to ${name} (vendor: ${vendor}, ${bmc_address})..."

  # shellcheck disable=SC2154
  if upload_bmc_cert "${bmc_address}" "${CERT_FILE}" \
     "${redfish_user}" "${redfish_password}" "${name}"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # Brief pause between uploads
  sleep 2
done

echo ""
echo "  Upload results: ${SUCCESS_COUNT} successful, ${FAIL_COUNT} failed"
echo ""

# Fail if no certificates were uploaded or if any uploads failed (after completing all attempts)
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "ERROR: Certificate upload failed."
  echo "  Successful uploads: ${SUCCESS_COUNT}"
  echo "  Failed uploads: ${FAIL_COUNT}"
  exit 1
fi

# Create patch file with CA certificate for install-config.yaml
echo "Creating patch file with BMC CA certificate..."
cat > "${SHARED_DIR}/bmc_ca_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    bmcVerifyCA: |
$(sed 's/^/      /' "${CA_CERT}")
EOF

echo ""
echo "=== BMC Certificate Setup Complete ==="
echo ""
echo "CA Certificate: ${CA_CERT}"
echo "Patch file: ${SHARED_DIR}/bmc_ca_patch_install_config.yaml"
echo ""
echo "The bmcVerifyCA field will be merged into install-config.yaml automatically."
echo ""
