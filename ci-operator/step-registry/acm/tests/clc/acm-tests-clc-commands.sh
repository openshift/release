#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


# THE FOLLOWING IS JUST FOR EXAMPLE PURPOSES FOR NOW.
ls -al

# Define the variables needed to create the MTR test configuration file. The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Example of setting a secret in the test script.
EXAMPLE_CLC_SECRET=$(cat ${SECRETS_DIR}/clc/example_clc_secret)

# Login to the Hub cluster
oc login --insecure-skip-tls-verify -u $HUB_OCP_USERNAME -p $HUB_OCP_PASSWORD $HUB_OCP_API_URL

# Run the script that gets the manmaged clusters created on the Hub
python3 generate_managedclusters_data.py
# Get the managed clusters info
cat managedClusters.json |jq -r '.managedClusters[0].name' > /tmp/managed.cluster.name
cat /tmp/managed.cluster.name
cat managedClusters.json |jq -r '.managedClusters[0].base_domain' > /tmp/managed.cluster.base.domain
cat /tmp/managed.cluster.base.domain
cat managedClusters.json |jq -r '.managedClusters[0].api_url' > /tmp/managed.cluster.api.url
cat /tmp/managed.cluster.api.url
cat managedClusters.json |jq -r '.managedClusters[0].username' > /tmp/managed.cluster.username
cat /tmp/managed.cluster.username
cat managedClusters.json |jq -r '.managedClusters[0].password' > /tmp/managed.cluster.password
cat /tmp/managed.cluster.password


# cat managedClusters.json |jq -r '.managedClusters[0].name' > managed.cluster.name
# cat managed.cluster.name
# cat managedClusters.json |jq -r '.managedClusters[0].base_domain' > managed.cluster.base.domain
# cat managed.cluster.base.domain
# cat managedClusters.json |jq -r '.managedClusters[0].api_url' > managed.cluster.api.url
# cat managed.cluster.api.url
# cat managedClusters.json |jq -r '.managedClusters[0].username' > managed.cluster.username
# cat managed.cluster.username
# cat managedClusters.json |jq -r '.managedClusters[0].password' > managed.cluster.password
# cat managed.cluster.password