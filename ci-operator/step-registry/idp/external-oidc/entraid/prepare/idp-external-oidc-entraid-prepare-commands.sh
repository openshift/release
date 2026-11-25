#!/usr/bin/env bash

set -euo pipefail

echo "Preparing yaml file for patch"
ISSUER_URL="$(</var/run/hypershift-ext-oidc-app-cli/issuer-url)"
CLI_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-cli/client-id)"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CLIENT_SECRET_VALUE="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
CONSOLE_CLIENT_SECRET_NAME=console-secret

# Prepare the entra id oidc provider file
cat > "$SHARED_DIR"/oidcProviders.json << EOF
{
  "oidcProviders": [
    {
      "claimMappings": {
        "groups": {"claim": "groups", "prefix": "oidc-groups-test:"},
        "username": {"claim": "email", "prefixPolicy": "Prefix", "prefix": {"prefixString": "oidc-user-test:"}}
      },
      "issuer": {
        "issuerURL": "$ISSUER_URL", "audiences": ["$CLI_CLIENT_ID", "$CONSOLE_CLIENT_ID"]
      },
      "name": "microsoft-entra-id",
      "oidcClients": [
        {"clientID": "$CLI_CLIENT_ID", "componentName": "cli", "componentNamespace": "openshift-console"},
        {
          "componentName": "console", "componentNamespace": "openshift-console", "clientID": "$CONSOLE_CLIENT_ID",
          "clientSecret": {"name": "$CONSOLE_CLIENT_SECRET_NAME"}
        }
      ]
    }
  ],
  "type": "OIDC"
}
EOF

if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
    echo "setting the proxy"
    echo "source ${SHARED_DIR}/proxy-conf.sh"
    source "${SHARED_DIR}/proxy-conf.sh"
else
    echo "no proxy setting."
fi

oc create secret generic $CONSOLE_CLIENT_SECRET_NAME --from-literal=clientSecret=$CONSOLE_CLIENT_SECRET_VALUE --dry-run=client -o yaml > "$SHARED_DIR"/oidcProviders-secret-configmap.yaml
