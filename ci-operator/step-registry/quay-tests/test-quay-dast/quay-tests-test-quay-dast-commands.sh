#!/bin/bash

set -euo pipefail

echo "The current ZAP Version is:"
zap.sh -version

echo "Clone Redhat Rapidast Repository..."
cd /tmp && git clone https://github.com/RedHatProductSecurity/rapidast.git && cd rapidast || true

if [ ${QUAY_ENV} = 'STAGE_QUAY_IO' ]; then
   echo "Generating Stage Quay.io OpenAPI File..."
   curl https://stage.quay.io/api/v1/discovery > quay.json || true
   QUAY_URL="https://stage.quay.io"
   QUAY_SHORT_NAME="stagequayio"
   QUAY_ACCESS_TOKEN=$(cat /var/run/quay-qe-stagequayio-secret/oauth2token)
   QUAY_OAUTH2_TOEKN="Bearer $QUAY_ACCESS_TOKEN"
   cat quay.json | jq > openapi.json && cp openapi.json $ARTIFACT_DIR || true 
fi

if [ ${QUAY_ENV} = 'QUAY_IO' ]; then
   echo "Generating Quay.io OpenAPI File..."
   curl https://quay.io/api/v1/discovery > quay.json || true
   QUAY_URL="https://quay.io"
   QUAY_SHORT_NAME="quayio"
   QUAY_ACCESS_TOKEN=$(cat /var/run/quay-qe-quayio-secret/oauth2token)
   QUAY_OAUTH2_TOEKN="Bearer $QUAY_ACCESS_TOKEN"
   cat quay.json | jq > openapi.json && cp openapi.json $ARTIFACT_DIR || true 
fi

if [ ${QUAY_ENV} = 'QUAY' ]; then
   echo "Generating Quay OpenAPI File..."
   QUAY_URL=$(cat "$SHARED_DIR"/quayroute)
   QUAY_SHORT_NAME="quay"
   QUAY_ACCESS_TOKEN=$(cat "$SHARED_DIR"/quay_oauth2_token)
   QUAY_OAUTH2_TOEKN="Bearer $QUAY_ACCESS_TOKEN"
   cat "$SHARED_DIR"/quay_api_discovery | jq > openapi.json && cp openapi.json $ARTIFACT_DIR || true 
fi


cat >>config-zap-prowci.yaml <<EOF
config:
  # WARNING: `configVersion` indicates the schema version of the config file.
  # This value tells RapiDAST what schema should be used to read this configuration.
  # Therefore you should only change it if you update the configuration to a newer schema
  # It is intended to keep backward compatibility (newer RapiDAST running an older config)
  configVersion: 5
# `application` contains data related to the application, not to the scans.
application:
  shortName: "${QUAY_SHORT_NAME}"
  url: "${QUAY_URL}"
# `general` is a section that will be applied to all scanners.
general:
  #proxy:
    #proxyHost: "squid.corp.redhat.com"
    #proxyPort: "3128"
  authentication:
    type: "http_header"
    parameters:
      name: "Authorization"
      #value_from_var: "EXPORTED_TOKEN"
      value: "${QUAY_OAUTH2_TOEKN}"
  container:
    type: "none"
scanners:
  zap:
  # Define a scan through the ZAP scanner
    apiScan:
      apis:
        # apiFile: "path/to/local/openapi-schema"
        apiFile: "openapi.json"
    passiveScan:
      # optional list of passive rules to disable
      disabledRules: "2,10015,10024,10027,10054,10096,10109,10112"
    activeScan:
      policy: "API-scan-minimal"
    container:
      parameters:
        image: "docker.io/owasp/zap2docker-stable:latest"
        executable: "zap.sh"
    miscOptions:
      # List (comma-separated string or list) of additional addons to install
      additionalAddons: "ascanrulesBeta"
EOF

cp config-zap-prowci.yaml config || true
./rapidast.py --config ./config/config-zap-prowci.yaml || true
mv results $ARTIFACT_DIR || true