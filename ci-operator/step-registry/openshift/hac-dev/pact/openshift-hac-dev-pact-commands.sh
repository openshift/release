#!/bin/bash

PACT_BROKER_USERNAME=$(cat /usr/local/ci-secrets/pact/pact-username)
PACT_BROKER_PASSWORD=$(cat /usr/local/ci-secrets/pact/pact-password)
PACT_BROKER_URL=$(cat /usr/local/ci-secrets/pact/pact-broker-url)

npm i
npm run pact
cat pact/pacts/HACdev-HAS.json
curl -v -X PUT \
    -H "Content-Type: application/json" \
    -d@pact/pacts/HACdev-HAS.json \
    -u ${PACT_BROKER_USERNAME}:${PACT_BROKER_PASSWORD} \
    ${PACT_BROKER_URL}/pacts/provider/HAS/consumer/HACdev/version/testversion
