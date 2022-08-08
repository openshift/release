#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This step wants to always talk to the build farm (via service account credentials) but ci-operator
# gives steps KUBECONFIG pointing to cluster under test under some circumstances, which is never
# the correct cluster to interact with for this step.
unset KUBECONFIG

# The cluster-bot service account (ci:ci-chat-bot) polls for extracts launch information
# from a secret written to the namespace.
oc -n "${NAMESPACE}" create role "ci-chat-bot-secret-reader-${BUILD_ID}" --verb get --resource=secrets --resource-name="${JOB_NAME_SAFE}"
oc -n "${NAMESPACE}" create rolebinding "ci-chat-bot-secret-reader-binding-${BUILD_ID}" --serviceaccount "ci:ci-chat-bot" --role "ci-chat-bot-secret-reader-${BUILD_ID}"


# Grant Cluster-bot roles to allow giving access to  cluster-initiators

# allow the cluster-bot service account (ci:ci-chat-bot) to create a RoleBinding in the namespace
oc -n "${NAMESPACE}" create role "ci-chat-bot-role-binder-${BUILD_ID}" --verb create --resource=rolebindings
oc -n "${NAMESPACE}" create rolebinding "ci-chat-bot-role-binder-binding-${BUILD_ID}" --serviceaccount "ci:ci-chat-bot" --role "ci-chat-bot-role-binder-${BUILD_ID}"

# grand permission (explicitly) to the cluster-bot service account (ci:ci-chat-bot) to bind `admin resourceName
oc -n "${NAMESPACE}" create role "ci-chat-bot-role-grantor-${BUILD_ID}" --verb bind --resource=clusterroles --resource-name=admin
oc -n "${NAMESPACE}" create rolebinding "ci-chat-bot-role-grantor-binding-${BUILD_ID}" --serviceaccount "ci:ci-chat-bot" --role "ci-chat-bot-role-grantor-${BUILD_ID}"


