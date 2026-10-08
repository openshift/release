#! /bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting step build-github-secrets."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping copy of build e2e GitHub source clone secrets."
    exit 0
fi

echo "Storing build e2e GitHub source clone secrets in namespace build-e2e-github-secrets."
oc new-project build-e2e-github-secrets

# Copy source clone secrets from CI to the cluster under test
# Specifying a directory will iterate over all files in the directory, and use the file's name as
# the key in the new secret

echo "Adding GitHub http token secret to cluster under test."
httpTokenDir="/var/run/secrets/ci/github-http-token" 
if [[ -d ${httpTokenDir} ]]; then
    echo "Contents of mounted github-http-token:"
    ls -al ${httpTokenDir}
    echo "Creating github-http-token secret in cluster under test."
    oc create secret generic github-http-token \
        -n build-e2e-github-secrets \
        --from-file="${httpTokenDir}/username" \
        --from-file="${httpTokenDir}/password" \
        --type=kubernetes.io/basic-auth \
        --request-timeout=10s
else
    echo "WARNING - GitHub http token not found and was not copied."
fi

echo "Adding GitHub SSH private key to cluster under test."
sshKeyDir="/var/run/secrets/ci/github-ssh-privatekey"
if [[ -d ${sshKeyDir} ]]; then
    echo "Contents of mounted github-ssh-privatekey:"
    ls -al ${sshKeyDir}
    echo "Creating github-ssh-privatekey secret in cluster under test."
    oc create secret generic github-ssh-privatekey \
        -n build-e2e-github-secrets \
        --from-file="${sshKeyDir}/ssh-privatekey" \
        --type=kubernetes.io/ssh-auth \
        --request-timeout=10s
else
    echo "WARNING - GitHub ssh private key not found and was not copied."
fi

echo "Step build-github-secrets completed."
