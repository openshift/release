#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


oc create namespace $NAMESPACE || true

oc create secret generic -n $NAMESPACE assisted-chat-ssl-ci --from-file=client_id=/var/run/secrets/sso-ci/client_id \
                                                            --from-file=client_secret=/var/run/secrets/sso-ci/client_secret

sleep 7200
oc process -p IMAGE_NAME=$ASSISTED_CHAT_TEST -p GEMINI_API_SECRET_NAME=gemini-api-key -p SSL_CLIENT_SECRET_NAME=assisted-chat-ssl-ci -f test/prow/template.yaml --local | oc apply -n $NAMESPACE -f -
