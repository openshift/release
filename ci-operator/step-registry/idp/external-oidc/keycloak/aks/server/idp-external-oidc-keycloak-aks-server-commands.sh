#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Insall helm binary
wget https://get.helm.sh/helm-v3.17.2-linux-amd64.tar.gz -O /tmp/helm.tar.gz
tar -xvf /tmp/helm.tar.gz -C /tmp/
chmod +x /tmp/linux-amd64/helm

KEYCLOAK_ADMIN_TEST_USER="admin-$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 6 | head -n 1 || true)"
KEYCLOAK_ADMIN_TEST_PASSWORD="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)"
KEYCLOAK_PREFIX="keycloak-$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 9 | head -n 1 || true)"
KEYCLOAK_HOST="$KEYCLOAK_PREFIX.$HYPERSHIFT_BASE_DOMAIN"
CLUSTER_CONSOLE="$(oc whoami --show-console)"
CONSOLE_CLIENT_SECRET_VALUE=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 32 | head -n 1 || true)

# Generate random test users for testing
TEST_USERS=""
for i in $(seq 1 50);
do
    username="keycloak-testuser-${i}"
    password=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
    TEST_USERS+="${username}:${password},"
done
# The users will be mounted into keycloak pods and the real test users will be created there
TEST_USERS=${TEST_USERS%?}

# Install NGINX Ingress Controller
/tmp/linux-amd64/helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
/tmp/linux-amd64/helm repo update
/tmp/linux-amd64/helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait

# Install cert-manager
oc create namespace cert-manager || true
oc apply -f https://github.com/jetstack/cert-manager/releases/download/v1.13.0/cert-manager.yaml
oc wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
# Create Let's Encrypt ClusterIssuer
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: openshift-qe@redhat.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
oc wait --for=condition=ready clusterissuer letsencrypt-prod --timeout=120s

# Set Keycloak repo
/tmp/linux-amd64/helm repo add bitnami https://charts.bitnami.com/bitnami
/tmp/linux-amd64/helm repo update

# Create Keycloak settings file
cat > /tmp/keycloak-values.yaml << EOF
nameOverride: ""
fullnameOverride: ""
namespace: keycloak

auth:
  adminUser: ${KEYCLOAK_ADMIN_TEST_USER}
  adminPassword: "${KEYCLOAK_ADMIN_TEST_PASSWORD}"
image:
  registry: docker.io
  repository: bitnamilegacy/keycloak
  tag: 26.3.3-debian-12-r0
  pullPolicy: IfNotPresent

securityContext:
  enabled: true
  fsGroup: 1001
  runAsUser: 1001
  runAsNonRoot: true

envFrom:
  - configMapRef:
      name: "keycloak-env-vars"
  - secretRef:
      name: "keycloak"

extraVolumes:
  - name: setup-scripts
    configMap:
      name: "keycloak-setup-scripts"
      defaultMode: 0755

extraVolumeMounts:
  - name: setup-scripts
    mountPath: /opt/bitnami/keycloak/setup-scripts/
    readOnly: true

lifecycleHooks:
  postStart:
    exec:
      command:
        - /bin/bash
        - -c
        - |
          #!/bin/bash
          set -euo pipefail

          echo "Waiting for Keycloak server to be ready..."
          timeout 10m bash -c 'while true; do
            if curl -s http://localhost:${KC_HTTP_PORT:-8080}/health/ready; then
              echo "Keycloak server is ready. Starting initialization..."
              break
            fi
            sleep 5
          done' || {
            echo "ERROR: Timeout waiting for Keycloak server"
            exit 1
          }

          echo "Executing setup-script.sh..."
          /opt/bitnami/keycloak/setup-scripts/setup-script.sh &> /tmp/postStart.log || true

extraDeploy:
  - |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: keycloak-setup-scripts
      namespace: keycloak
    data:
      setup-script.sh: |
        #!/bin/bash
        set -euox pipefail
        export PATH=\$PATH:/opt/bitnami/keycloak/bin
        KCADM_CONFIG=/tmp/.keycloak-kcadm.config

        echo "Authenticating with admin user: \${KC_BOOTSTRAP_ADMIN_USERNAME}"
        kcadm.sh config credentials \
          --server http://localhost:\${KC_HTTP_PORT:-8080} \
          --realm master \
          --user "\${KC_BOOTSTRAP_ADMIN_USERNAME}" \
          --password "\$(cat "\${KC_BOOTSTRAP_ADMIN_PASSWORD_FILE}")" \
          --config=\${KCADM_CONFIG}

        echo "Setting realms/master ssoSessionIdleTimeout"
        kcadm.sh update realms/master -s ssoSessionIdleTimeout=7200 --config=/tmp/.keycloak-kcadm.config

        echo "Creating client: oc-cli-test"
        if ! kcadm.sh get clients -r master --config=\${KCADM_CONFIG} | grep -q "oc-cli-test"; then
          kcadm.sh create clients -r master -f /opt/bitnami/keycloak/setup-scripts/client-oc-cli-test.json --config=\${KCADM_CONFIG}
        fi
        CLIENT_OC_CLI_TEST_ID=\$(kcadm.sh get clients -r master --config=\${KCADM_CONFIG} -q clientId=oc-cli-test --fields id --format csv --noquotes)
        echo "Creating client: console-test"
        if ! kcadm.sh get clients -r master --config=\${KCADM_CONFIG} | grep -q "console-test"; then
          kcadm.sh create clients -r master -f /opt/bitnami/keycloak/setup-scripts/client-console-test.json --config=\${KCADM_CONFIG}
        fi
        CLIENT_CONSOLE_TEST_ID=\$(kcadm.sh get clients -r master --config=\${KCADM_CONFIG} -q clientId=console-test --fields id --format csv --noquotes)
        echo "Adding group mappers"
        for CLIENT_ID in "\${CLIENT_OC_CLI_TEST_ID}" "\${CLIENT_CONSOLE_TEST_ID}"; do
          if ! kcadm.sh get clients/\${CLIENT_ID}/protocol-mappers/models -r master --config=\${KCADM_CONFIG} | grep -q "groupmapper"; then
            kcadm.sh create clients/\${CLIENT_ID}/protocol-mappers/models \
              -f /opt/bitnami/keycloak/setup-scripts/groupmapper-for-clients.json \
              --config=\${KCADM_CONFIG}
          fi
        done

        echo "Creating test group"
        if ! kcadm.sh get groups -r master --config=\${KCADM_CONFIG} | grep -q "keycloak-testgroup-1"; then
          kcadm.sh create groups -r master -s name="keycloak-testgroup-1" --config=\${KCADM_CONFIG}
        fi
        TEST_GROUP_ID=\$(kcadm.sh get groups -r master --config=\${KCADM_CONFIG} -q name=keycloak-testgroup-1 --fields id --format csv --noquotes)
        echo "Creating test users"
        IFS=',' read -ra USER_LIST <<< "\$(cat /opt/bitnami/keycloak/setup-scripts/testusers)"
        for USER in "\${USER_LIST[@]}"; do
          TEST_USER_NAME=\$(echo "\${USER}" | cut -d ':' -f 1)
          TEST_USER_PASSWORD=\$(echo "\${USER}" | cut -d ':' -f 2)

          kcadm.sh create users -r master \
            -s username="\${TEST_USER_NAME}" \
            -s enabled=true \
            -s firstName="\${TEST_USER_NAME}" \
            -s lastName=KC \
            -s email="\${TEST_USER_NAME}@example.com" \
            -s emailVerified=true \
            --config=\${KCADM_CONFIG}
          TEST_USER_ID=\$(kcadm.sh get users -r master --config=\${KCADM_CONFIG} -q username=\${TEST_USER_NAME} --fields id --format csv --noquotes)

          kcadm.sh set-password -r master \
            --username "\${TEST_USER_NAME}" \
            --new-password "\${TEST_USER_PASSWORD}" \
            --temporary=false \
            --config=\${KCADM_CONFIG}
    
          kcadm.sh update users/\${TEST_USER_ID}/groups/\${TEST_GROUP_ID} -r master \
            -s realm=master \
            -s userId="\${TEST_USER_ID}" \
            -s groupId="\${TEST_GROUP_ID}" \
            --no-merge \
            --config=\${KCADM_CONFIG}
        done

        echo "Keycloak initialization completed successfully"

      client-oc-cli-test.json: |
        {
          "clientId" : "oc-cli-test",
          "enabled" : true,
          "redirectUris" : [ "http://localhost:8080" ],
          "webOrigins" : [ "http://localhost:8080" ],
          "standardFlowEnabled" : true,
          "directAccessGrantsEnabled" : true,
          "publicClient" : true,
          "frontchannelLogout" : true,
          "protocol" : "openid-connect",
          "attributes" : {
            "oidc.ciba.grant.enabled" : "false",
            "backchannel.logout.session.required" : "true",
            "oauth2.device.authorization.grant.enabled" : "false",
            "backchannel.logout.revoke.offline.tokens" : "false",
            "client.session.idle.timeout" : "7200"
          }
        }
      client-console-test.json: |
        {
          "clientId" : "console-test",
          "enabled" : true,
          "secret" : "${CONSOLE_CLIENT_SECRET_VALUE}",
          "redirectUris" : [ "${CLUSTER_CONSOLE}/auth/callback" ],
          "webOrigins" : [ "${CLUSTER_CONSOLE}" ],
          "standardFlowEnabled" : true,
          "directAccessGrantsEnabled" : true,
          "publicClient" : false,
          "frontchannelLogout" : true,
          "protocol" : "openid-connect",
          "attributes" : {
            "oidc.ciba.grant.enabled" : "false",
            "backchannel.logout.session.required" : "true",
            "oauth2.device.authorization.grant.enabled" : "false",
            "backchannel.logout.revoke.offline.tokens" : "false",
            "client.session.idle.timeout" : "7200"
          }
        }
      groupmapper-for-clients.json: |
        {
          "name" : "groupmapper",
          "protocol" : "openid-connect",
          "protocolMapper" : "oidc-group-membership-mapper",
          "consentRequired" : false,
          "config" : {
            "full.path" : "false",
            "userinfo.token.claim" : "true",
            "id.token.claim" : "true",
            "access.token.claim" : "false",
            "claim.name" : "groups"
          }
        }
      testusers: |
        ${TEST_USERS}

keycloak:
  extraEnv:
    - name: KC_PROXY
      value: "edge"
    - name: KC_HTTP_PORT
      value: "8080"
    - name: KC_LOG_LEVEL
      value: "INFO"
  http:
    enabled: true
  https:
    enabled: true
  hostname:
    hostname: ${KEYCLOAK_HOST}
    strict: false
  jvm:
    memory:
      initial: 512m
      max: 1024m

ingress:
  enabled: true
  hostname: ${KEYCLOAK_HOST}
  ingressClassName: nginx 
  path: /
  pathType: Prefix
  tls: true
  tlsSecret: ${KEYCLOAK_HOST}-tls
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTP
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: letsencrypt-prod

postgresql:
  image:
    registry: docker.io
    repository: bitnamilegacy/postgresql
    tag: 17.6.0-debian-12-r0

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1000m
    memory: 2Gi

service:
  type: ClusterIP
  port: 80
  targetPort: 8080
  https:
    port: 443
    targetPort: 8443
EOF

# Install Keycloak from helm chart
/tmp/linux-amd64/helm install keycloak bitnami/keycloak \
  --namespace keycloak \
  --create-namespace \
  --values /tmp/keycloak-values.yaml \
  --timeout 30m \
  --wait

oc get pods,svc,ing -n keycloak

# Save user info and Keycloak host info to shared dir for later use
KEYCLOAK_ISSUER=https://${KEYCLOAK_HOST}/realms/master
CONSOLE_CLIENT_ID=console-test
CONSOLE_CLIENT_SECRET_NAME=authid-console-openshift-console
CLI_CLIENT_ID=oc-cli-test
AUDIENCE_1=${CONSOLE_CLIENT_ID}
AUDIENCE_2=${CLI_CLIENT_ID}

# If the secret is managed by customer, we will create an empty secret here,
# then create the secret in hosted cluster later.
if [[ "${OIDC_SECRET_MANAGED_BY_CUSTOMER}" == "true" ]] ; then
    cat > "${SHARED_DIR}"/oidcProviders-secret-configmap.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  annotations:
    hypershift.openshift.io/hosted-cluster-sourced: "true"
  creationTimestamp: null
  name: ${CONSOLE_CLIENT_SECRET_NAME}
EOF
else
    oc create secret generic ${CONSOLE_CLIENT_SECRET_NAME} --from-literal=clientSecret=${CONSOLE_CLIENT_SECRET_VALUE} --dry-run=client -o yaml > "${SHARED_DIR}"/oidcProviders-secret-configmap.yaml
fi
# Spaces or symbol characters in below "name" should work, in case of similar bug OCPBUGS-44099 in old IDP area
cat > "${SHARED_DIR}"/oidcProviders.json << EOF
{
  "oidcProviders": [
    {
      "claimMappings": {
        "groups": {"claim": "groups", "prefix": "oidc-groups-test:"},
        "username": {"claim": "email", "prefixPolicy": "Prefix", "prefix": {"prefixString": "oidc-user-test:"}}
      },
      "issuer": {
        "issuerURL": "${KEYCLOAK_ISSUER}", "audiences": ["${AUDIENCE_1}", "${AUDIENCE_2}"],
        "issuerCertificateAuthority": {"name": "keycloak-oidc-ca"}
      },
      "name": "keycloak oidc server",
      "oidcClients": [
        {"clientID": "${CLI_CLIENT_ID}", "componentName": "cli", "componentNamespace": "openshift-console"},
        {
          "componentName": "console", "componentNamespace": "openshift-console", "clientID": "${CONSOLE_CLIENT_ID}",
          "clientSecret": {"name": "${CONSOLE_CLIENT_SECRET_NAME}"}
        }
      ]
    }
  ],
  "type": "OIDC"
}
EOF

if [ -f "${SHARED_DIR}/runtime_env" ] ; then
    source "${SHARED_DIR}/runtime_env"
fi

cat << EOF >> "${SHARED_DIR}/runtime_env"
export KEYCLOAK_ISSUER="https://${KEYCLOAK_HOST}/realms/master"
export KEYCLOAK_TEST_USERS="${TEST_USERS}"
export KEYCLOAK_CLI_CLIENT_ID="oc-cli-test"
export CONSOLE_CLIENT_SECRET_VALUE="${CONSOLE_CLIENT_SECRET_VALUE}"
export CONSOLE_CLIENT_ID="console-test"
EOF

echo ${KEYCLOAK_PREFIX} > ${SHARED_DIR}/keycloak-prefix
echo "export OAUTH_EXTERNAL_OIDC_PROVIDER=keycloak" > ${SHARED_DIR}/keycloak-provider
