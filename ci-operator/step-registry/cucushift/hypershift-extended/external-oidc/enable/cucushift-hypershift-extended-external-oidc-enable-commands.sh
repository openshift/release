#!/usr/bin/env bash

set -euo pipefail

echo "Preparing yaml file for patch"
ISSUER_URL="$(</var/run/hypershift-ext-oidc-app-cli/issuer-url)"
CLI_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-cli/client-id)"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
CONSOLE_CLIENT_SECRET_NAME=console-secret

# Generate the main part of the patch.yaml
cat <<EOF > /tmp/patch.yaml
spec:
  configuration:
    authentication:
      oidcProviders:
      - claimMappings:
          groups:
            claim: groups
            prefix: 'oidc-groups-test:'
          username:
            claim: email
            prefixPolicy: Prefix
            prefix:
              prefixString: 'oidc-user-test:'
        issuer:
          audiences:
          - ${CLI_CLIENT_ID}
          - ${CONSOLE_CLIENT_ID}
          issuerURL: ${ISSUER_URL}
        name: microsoft-entra-id
        oidcClients:
        - clientID: ${CONSOLE_CLIENT_ID}
          clientSecret:
            name: ${CONSOLE_CLIENT_SECRET_NAME}
          componentName: console
          componentNamespace: openshift-console
EOF

# Conditionally append the CLI OIDC client part
if [[ "$EXT_OIDC_INCLUDE_CLI_CLIENT" == "true" ]]; then
    echo "Appending the CLI OIDC client"
    cat <<EOF >> /tmp/patch.yaml
        - componentName: cli
          componentNamespace: openshift-console
          clientID: ${CLI_CLIENT_ID}
EOF
fi

# Append the remaining part of the YAML
cat <<EOF >> /tmp/patch.yaml
      type: OIDC
EOF

echo "Patching rendered artifacts"
yq-v4 'select(.kind == "HostedCluster") *= load("/tmp/patch.yaml")' "${SHARED_DIR}"/hypershift_create_cluster_render.yaml \
    > "${SHARED_DIR}"/hypershift_create_cluster_render_ext_oidc_enabled.yaml

echo "Applying patched artifacts"
oc apply -f "${SHARED_DIR}"/hypershift_create_cluster_render_ext_oidc_enabled.yaml

echo "Creating the console client secret"
oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n clusters --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET"
