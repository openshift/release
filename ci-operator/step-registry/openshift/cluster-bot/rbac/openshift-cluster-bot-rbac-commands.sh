#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# The cluster-bot service account (ci:ci-chat-bot) polls for extracts launch information
# from a secret written to the namespace.
oc -n "${NAMESPACE}" create role "secret-reader" --verb get --resource=secrets --resource-name="${JOB_NAME_SAFE}"
oc -n "${NAMESPACE}" create rolebinding "ci-chat-bot-secret-reader-binding" --serviceaccount "ci:ci-chat-bot" --role "secret-reader"
