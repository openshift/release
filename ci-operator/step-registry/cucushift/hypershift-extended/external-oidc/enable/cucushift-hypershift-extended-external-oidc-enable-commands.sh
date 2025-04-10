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
          extra:
          - key: extratest.openshift.com/foo
            valueExpression: claims.email
          - key: extratest.openshift.com/bar
            valueExpression: '"extra-test-mark"'
          uid:
            expression: '"testuid-" + claims.sub + "-uidtest"'
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
# TODO HOSTED_CLUSTER_VERSION is a placeholder for now, how to get its value?
if [[ $(awk "BEGIN {print ($HOSTED_CLUSTER_VERSION >= 4.18)}") == "1"  ]]; then
   oc get -f "${SHARED_DIR}"/hypershift_create_cluster_render_ext_oidc_enabled.yaml -o jsonpath='{.spec.configuration.authentication.oidcProviders[*].claimMappings}' > /tmp/created_claimMappings.json
   if grep 'extratest.*foo.*claims.email.*bar.*claims.sub.*uidtest' /tmp/created_claimMappings.json; then
        echo "HostedCluster: External OIDC uid and extra settings are honored."
   else
        echo "HostedCluster: External OIDC uid and extra settings are not honored."
        cat /tmp/created_claimMappings.json
	exit 1
   fi
fi

# TODO: will also check the uid and extra settings are propogated to hosted cluster's authentication CR

echo "Creating the console client secret"
oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n clusters --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET"
