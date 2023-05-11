#!/bin/bash

PACT_BROKER_USERNAME=$(cat /usr/local/ci-secrets/pact/pact-username)
PACT_BROKER_PASSWORD=$(cat /usr/local/ci-secrets/pact/pact-password)
PACT_BROKER_BASE_URL=$(cat /usr/local/ci-secrets/pact/pact-broker-url)

SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')
PR_NUMBER=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')

npm i
npm run pact

wget -qO- https://github.com/pact-foundation/pact-ruby-standalone/releases/download/v1.92.0/pact-1.92.0-linux-x86_64.tar.gz | tar xz --one-top-level=./pactcli
PATH=${PATH}:$(pwd)/pactcli/pact/bin

pact-broker publish \
 "$(pwd)/pact/pacts/HACdev-HAS.json" \
 -a ${SHA:0:7} \
 -t PR${PR_NUMBER} \
 -b $PACT_BROKER_BASE_URL \
 -u $PACT_BROKER_USERNAME \
 -p $PACT_BROKER_PASSWORD
