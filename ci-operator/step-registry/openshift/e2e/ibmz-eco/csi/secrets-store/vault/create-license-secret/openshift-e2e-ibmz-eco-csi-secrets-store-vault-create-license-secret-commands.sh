#!/bin/bash

set -x
echo"$(date) Fetching the vault license from Vault Server"
oc -n vault create secret generic vault-license --from-file=license=/etc/hypershift-agent-ibmz-credentials/vault-license
oc get secret vault-license -n vault >/dev/null 2>&1 || { echo "Vault License Secret missing!"; exit 1; }