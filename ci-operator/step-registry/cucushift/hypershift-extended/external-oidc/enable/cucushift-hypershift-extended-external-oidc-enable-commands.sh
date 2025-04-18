#!/usr/bin/env bash

set -euo pipefail

echo "Preparing yaml file for patch"
ISSUER_URL="$(</var/run/hypershift-ext-oidc-app-cli/issuer-url)"
CLI_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-cli/client-id)"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
CONSOLE_CLIENT_SECRET_NAME=console-secret

# Generate the main part of the patch.yaml
# Note, the value examples (e.g. extra's values) in this patch.yaml may be tested and referenced otherwhere.
# So, when modifying them, search and modify otherwhere too
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
          - key: extratest.openshift.com/bar
            valueExpression: '"extra-test-mark"'
          - key: extratest.openshift.com/foo
            valueExpression: claims.email
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

HOSTED_CLUSTER_RELEASE=$(yq-v4 'select(.kind == "HostedCluster") | .spec.release.image' "${SHARED_DIR}"/hypershift_create_cluster_render.yaml)
HOSTED_CLUSTER_NAME=$(yq-v4 'select(.kind == "HostedCluster") | .metadata.name' "${SHARED_DIR}"/hypershift_create_cluster_render.yaml)
yq-v4 "select(.metadata.name == \"$HOSTED_CLUSTER_NAME-pull-secret\") | .data.\".dockerconfigjson\"" "${SHARED_DIR}"/hypershift_create_cluster_render.yaml | base64 -d > /tmp/hosted_cluster_pull_secret
HOSTED_CLUSTER_VERSION=$(oc image info -a /tmp/hosted_cluster_pull_secret $HOSTED_CLUSTER_RELEASE | grep -o 'io.openshift.release=.*' | grep -Eo '=4\.[0-9]+' | grep -Eo '[^=]+')
echo "The hosted cluster minor version is: $HOSTED_CLUSTER_VERSION"
rm -f /tmp/hosted_cluster_pull_secret

echo "Checking External OIDC uid and extra settings ..."
echo "First, checking ExternalOIDCWithUIDAndExtraClaimMappings featuregate ..."
if [[ $(awk "BEGIN {print ($HOSTED_CLUSTER_VERSION >= 4.18)}") == "1"  ]]; then
    # Once the ExternalOIDCWithUIDAndExtraClaimMappings feature PRs are merged and backported to 4.18, remove the `curl` line
    if curl -sS https://raw.githubusercontent.com/openshift/api/refs/heads/release-"$HOSTED_CLUSTER_VERSION"/payload-manifests/featuregates/featureGate-Hypershift-Default.yaml | yq-v4 '.status.featureGates[].enabled' | grep -q ExternalOIDCWithUIDAndExtraClaimMappings; then
        CREATED_CLAIM_MAPPINGS=$(oc get hc/"$HOSTED_CLUSTER_NAME" -o jsonpath='{.spec.configuration.authentication.oidcProviders[*].claimMappings}')
        if jq '.uid' <<< "$CREATED_CLAIM_MAPPINGS" | grep -q testuid && jq -c '.extra' <<< "$CREATED_CLAIM_MAPPINGS" | grep -q 'bar.*foo'; then
            echo "HostedCluster: External OIDC uid and extra settings are honored."
        else
            echo "$CREATED_CLAIM_MAPPINGS"
            echo "HostedCluster: External OIDC uid and extra settings are not honored!"
            exit 1
        fi
    fi
fi

echo "Creating the console client secret"
oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n clusters --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET"
