#!/bin/bash

PACT_BROKER_USERNAME=$(cat /usr/local/ci-secrets/pact/pact-username)
PACT_BROKER_PASSWORD=$(cat /usr/local/ci-secrets/pact/pact-password)
PACT_BROKER_BASE_URL=$(cat /usr/local/ci-secrets/pact/pact-broker-url)

PR_NUMBER=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')
JOB_TYPE=$(echo ${JOB_SPEC} | jq -r '.type')

npm i
npm run pact

wget -qO- https://github.com/pact-foundation/pact-ruby-standalone/releases/download/v1.92.0/pact-1.92.0-linux-x86_64.tar.gz | tar xz --one-top-level=./pactcli
PATH=${PATH}:$(pwd)/pactcli/pact/bin

if [[ $JOB_TYPE == "presubmit" ]]; then
    echo "Generating pacts, pushing with the PR number."
    SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')

    pact-broker publish \
    "$(pwd)/pact/pacts/HACdev-HAS.json" \
    -a ${SHA:0:7} \
    -t PR${PR_NUMBER} \
    -b $PACT_BROKER_BASE_URL \
    -u $PACT_BROKER_USERNAME \
    -p $PACT_BROKER_PASSWORD
else    
    echo "Executed post merge, pushing with the branch main."
    SHA=$(echo ${JOB_SPEC} | jq -r '.refs.base_sha')

    pact-broker publish \
    "$(pwd)/pact/pacts/HACdev-HAS.json" \
    -a ${SHA:0:7} \
    -b $PACT_BROKER_BASE_URL \
    -u $PACT_BROKER_USERNAME \
    -p $PACT_BROKER_PASSWORD \
    -h main
fi
