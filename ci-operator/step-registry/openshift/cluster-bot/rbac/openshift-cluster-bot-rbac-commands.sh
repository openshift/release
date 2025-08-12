#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This step wants to always talk to the build farm (via service account credentials) but ci-operator
# gives steps KUBECONFIG pointing to cluster under test under some circumstances, which is never
# the correct cluster to interact with for this step.
unset KUBECONFIG

# The cluster-bot service account (ci:ci-chat-bot) polls for and extracts launch information
# from a secret written to the namespace.
oc -n "${NAMESPACE}" create role "ci-chat-bot-secret-reader-${BUILD_ID}" --verb get --resource=secrets --resource-name="${JOB_NAME_SAFE}"
oc -n "${NAMESPACE}" create rolebinding "ci-chat-bot-secret-reader-binding-${BUILD_ID}" --serviceaccount "ci:ci-chat-bot" --role "ci-chat-bot-secret-reader-${BUILD_ID}"
