#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy Red Hat build of Keycloak (RHBK) into the Quay namespace as Quay's OIDC
# provider: RHBK operator, an ephemeral PostgreSQL, a Keycloak behind one edge
# Route, and the "quay" realm. The Quay config fragment is written only after the
# realm's discovery document answers with the expected issuer.
# The DB password is handled below, so this script never enables set -x.

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_NS="${QUAYNAMESPACE}"

# Remove stale outputs from a prior attempt so a retry never hands the deploy
# steps a fragment for an IdP that did not come up this run.
rm -f "${SHARED_DIR}/quay-auth-config.yaml" "${SHARED_DIR}/quay-auth-ca.crt" "${SHARED_DIR}/keycloak_host"

oc get namespace "${QUAY_NS}" >/dev/null 2>&1 || oc create namespace "${QUAY_NS}"

base_domain=$(oc get dns/cluster -o jsonpath='{.spec.baseDomain}')
KEYCLOAK_HOST="rhbk-${QUAY_NS}.apps.${base_domain}"
KEYCLOAK_URL="https://${KEYCLOAK_HOST}"
QUAY_HOST="quay-quay-${QUAY_NS}.apps.${base_domain}"

# OLM allows one OperatorGroup per namespace. deploy-aws-s3 applies one named
# "quay" with the same spec, so creating that name here lets its later apply
# update this object instead of adding a second one.
if [[ -z "$(oc get operatorgroup -n "${QUAY_NS}" -o name)" ]]; then
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: ${QUAY_NS}
spec:
  targetNamespaces:
  - ${QUAY_NS}
EOF
fi
echo "OperatorGroup in ${QUAY_NS}: $(oc get operatorgroup -n "${QUAY_NS}" -o name)"

channel="${RHBK_OPERATOR_CHANNEL}"
if [[ -z "${channel}" ]]; then
  channel=$(oc get packagemanifests -n openshift-marketplace -l catalog=redhat-operators -o json |
    jq -r '.items[] | select(.metadata.name == "rhbk-operator") | .status.defaultChannel')
fi
if [[ -z "${channel}" ]]; then
  echo "ERROR: no rhbk-operator packagemanifest in redhat-operators" >&2
  exit 1
fi
echo "Subscribing to rhbk-operator channel ${channel}"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${QUAY_NS}
spec:
  installPlanApproval: Automatic
  name: rhbk-operator
  channel: ${channel}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

CSV_READY=false
for _ in {1..60}; do
  CSV=$(oc -n "${QUAY_NS}" get subscription rhbk-operator -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "${CSV}" ]] && [[ "$(oc -n "${QUAY_NS}" get csv "${CSV}" -o jsonpath='{.status.phase}' || true)" == "Succeeded" ]]; then
    CSV_READY=true
    break
  fi
  sleep 10
done
if [[ "${CSV_READY}" != "true" ]]; then
  echo "ERROR: timed out waiting for the rhbk-operator CSV to reach Succeeded" >&2
  oc -n "${QUAY_NS}" describe subscription rhbk-operator >&2 || true
  oc -n "${QUAY_NS}" describe csv >&2 || true
  exit 1
fi
echo "rhbk-operator CSV ${CSV} Succeeded"

# The password exists only in this Secret. Keep an existing one: the database in
# the emptyDir was initialised with it, so a new password would lock Keycloak out.
if ! oc get secret rhbk-postgres -n "${QUAY_NS}" >/dev/null 2>&1; then
  db_password=$(head -c 18 /dev/urandom | base64 | tr -d '+/=')
  oc create secret generic rhbk-postgres -n "${QUAY_NS}" \
    --from-literal=username=keycloak --from-literal=password="${db_password}" >/dev/null
  unset db_password
fi

echo "Deploying PostgreSQL (${RHBK_POSTGRES_IMAGE}) into ${QUAY_NS}..."
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rhbk-postgres
  namespace: ${QUAY_NS}
  labels:
    app: rhbk-postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rhbk-postgres
  template:
    metadata:
      labels:
        app: rhbk-postgres
    spec:
      containers:
      - name: postgres
        image: ${RHBK_POSTGRES_IMAGE}
        ports:
        - name: postgres
          containerPort: 5432
        env:
        - name: POSTGRESQL_DATABASE
          value: keycloak
        - name: POSTGRESQL_USER
          valueFrom:
            secretKeyRef:
              name: rhbk-postgres
              key: username
        - name: POSTGRESQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: rhbk-postgres
              key: password
        readinessProbe:
          exec:
            command: ["pg_isready", "-h", "127.0.0.1", "-p", "5432"]
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
        volumeMounts:
        - name: data
          mountPath: /var/lib/pgsql/data
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: rhbk-postgres
  namespace: ${QUAY_NS}
  labels:
    app: rhbk-postgres
spec:
  selector:
    app: rhbk-postgres
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
EOF
oc rollout status deployment/rhbk-postgres -n "${QUAY_NS}" --timeout=5m

# v2alpha1 is served by every RHBK 26.x operator (deprecated, still served, in 26.6+).
cat <<EOF | oc apply -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: rhbk
  namespace: ${QUAY_NS}
spec:
  instances: 1
  db:
    vendor: postgres
    host: rhbk-postgres
    port: 5432
    database: keycloak
    usernameSecret:
      name: rhbk-postgres
      key: username
    passwordSecret:
      name: rhbk-postgres
      key: password
  http:
    httpEnabled: true
  hostname:
    hostname: ${KEYCLOAK_URL}
  proxy:
    headers: xforwarded
  ingress:
    enabled: false
EOF

oc create route edge rhbk --service=rhbk-service --port=http --hostname="${KEYCLOAK_HOST}" \
  --insecure-policy=Redirect -n "${QUAY_NS}" --dry-run=client -o yaml | oc apply -f -

echo "Waiting for Keycloak rhbk to be Ready..."
if ! oc wait keycloak/rhbk -n "${QUAY_NS}" --for=condition=Ready --timeout=15m; then
  echo "ERROR: Keycloak rhbk not Ready" >&2
  oc describe keycloak/rhbk -n "${QUAY_NS}" >&2 || true
  oc get pods -n "${QUAY_NS}" -o wide >&2 || true
  exit 1
fi

# Vendored verbatim from quay/quay redhat-3.18 (bc13b4a8306f7e6ca0fb3114a266a24da61a179c),
# local-dev/keycloak/quay-realm-export.json. Test-only users and client secrets.
REALM_JSON=$(cat <<'EOF'
{
  "realm": "quay",
  "enabled": true,
  "sslRequired": "none",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": false,
  "editUsernameAllowed": false,
  "bruteForceProtected": false,
  "rememberMe": false,
  "verifyEmail": false,
  "loginTheme": "keycloak",
  "accessTokenLifespan": 300,
  "clients": [
    {
      "clientId": "quay-ui",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": [
        "http://localhost:8080/*",
        "http://localhost:8080/oauth2/someoidc/callback*",
        "http://localhost:9000/*",
        "http://localhost:9000/oauth2/someoidc/callback*"
      ],
      "webOrigins": ["+"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "+"
      },
      "protocolMappers": [
        {
          "name": "quay-ui-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.client.audience": "quay-ui",
            "id.token.claim": "false",
            "access.token.claim": "true",
            "introspection.token.claim": "true"
          }
        }
      ]
    },
    {
      "clientId": "quay-unknown-aud",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "quay-unknown-aud-secret",
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": true,
      "redirectUris": ["http://localhost:8080/*"],
      "webOrigins": ["+"],
      "protocolMappers": [
        {
          "name": "wrong-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.custom.audience": "api://some-other-app",
            "id.token.claim": "false",
            "access.token.claim": "true",
            "introspection.token.claim": "true"
          }
        }
      ]
    },
    {
      "clientId": "quay-obo",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "quay-obo-secret",
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": true,
      "redirectUris": ["http://localhost:8080/*"],
      "webOrigins": ["+"],
      "protocolMappers": [
        {
          "name": "custom-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.custom.audience": "api://quay-api",
            "id.token.claim": "false",
            "access.token.claim": "true",
            "introspection.token.claim": "true"
          }
        }
      ]
    }
  ],
  "users": [
    {
      "username": "admin_oidc",
      "enabled": true,
      "emailVerified": true,
      "email": "admin_oidc@example.com",
      "firstName": "Admin",
      "lastName": "OIDC",
      "credentials": [
        {
          "type": "password",
          "value": "password",
          "temporary": false
        }
      ]
    },
    {
      "username": "testuser_oidc",
      "enabled": true,
      "emailVerified": true,
      "email": "testuser_oidc@example.com",
      "firstName": "Test",
      "lastName": "OIDC",
      "credentials": [
        {
          "type": "password",
          "value": "password",
          "temporary": false
        }
      ]
    },
    {
      "username": "readonly_oidc",
      "enabled": true,
      "emailVerified": true,
      "email": "readonly_oidc@example.com",
      "firstName": "Readonly",
      "lastName": "OIDC",
      "credentials": [
        {
          "type": "password",
          "value": "password",
          "temporary": false
        }
      ]
    }
  ]
}
EOF
)

jq -n --arg ns "${QUAY_NS}" --arg redirect "https://${QUAY_HOST}/*" --argjson realm "${REALM_JSON}" '{
  apiVersion: "k8s.keycloak.org/v2alpha1",
  kind: "KeycloakRealmImport",
  metadata: {name: "rhbk-quay", namespace: $ns},
  spec: {
    keycloakCRName: "rhbk",
    realm: ($realm | .clients |= map(if .clientId == "quay-ui" then .redirectUris = [$redirect] else . end))
  }
}' | oc apply -f -

echo "Waiting for KeycloakRealmImport rhbk-quay to be Done..."
if ! oc wait keycloakrealmimport/rhbk-quay -n "${QUAY_NS}" --for=condition=Done --timeout=10m; then
  echo "ERROR: realm import rhbk-quay not Done" >&2
  oc get keycloakrealmimport/rhbk-quay -n "${QUAY_NS}" -o jsonpath='{.status}' >&2 || true
  oc get pods -n "${QUAY_NS}" -o wide >&2 || true
  exit 1
fi

oc get keycloak/rhbk -n "${QUAY_NS}" -o json | jq '{name: .metadata.name, status}' \
  > "${ARTIFACT_DIR}/rhbk-keycloak-status.json" || true
oc get keycloakrealmimport/rhbk-quay -n "${QUAY_NS}" -o json | jq '{name: .metadata.name, status}' \
  > "${ARTIFACT_DIR}/rhbk-realm-import-status.json" || true

# Preflight: Quay validates the issuer against OIDC_ISSUERS, so prove the Route
# serves the realm under the exact issuer the fragment names. The Route can take
# a few seconds to program after admission, so retry briefly.
ISSUER="${KEYCLOAK_URL}/realms/quay"
issuer=""
for _ in $(seq 1 24); do
  issuer=$(curl -sk --max-time 10 "${ISSUER}/.well-known/openid-configuration" | jq -r '.issuer' 2>/dev/null || true)
  [[ "${issuer}" == "${ISSUER}" ]] && break
  sleep 5
done
if [[ "${issuer}" != "${ISSUER}" ]]; then
  echo "ERROR: ${ISSUER}/.well-known/openid-configuration issuer is '${issuer}', want '${ISSUER}'" >&2
  oc get route rhbk -n "${QUAY_NS}" -o yaml >&2 || true
  exit 1
fi
echo "Keycloak realm quay is serving issuer ${ISSUER}"

router_ca_dir=$(mktemp -d)
oc extract cm/default-ingress-cert -n openshift-config-managed --keys=ca-bundle.crt --to="${router_ca_dir}" --confirm
cp "${router_ca_dir}/ca-bundle.crt" "${SHARED_DIR}/quay-auth-ca.crt"
rm -rf "${router_ca_dir}"

printf '%s' "${KEYCLOAK_URL}" > "${SHARED_DIR}/keycloak_host"

cat <<EOF > "${SHARED_DIR}/quay-auth-config.yaml"
AUTHENTICATION_TYPE: OIDC
FEATURE_TEAM_SYNCING: true
FEATURE_USER_INITIALIZE: false
SUPER_USERS:
- admin_oidc
GLOBAL_READONLY_SUPER_USERS:
- readonly_oidc
SOMEOIDC_LOGIN_CONFIG:
  SERVICE_NAME: Keycloak
  OIDC_SERVER: ${ISSUER}/
  CLIENT_ID: quay-ui
  LOGIN_SCOPES:
  - openid
  - profile
  - email
  USE_PKCE: true
  PKCE_METHOD: S256
  PUBLIC_CLIENT: true
  OIDC_ISSUERS:
  - ${ISSUER}
  OIDC_AUDIENCES:
  - quay-ui
  - api://quay-api
  OIDC_ALLOWED_CLIENTS:
  - quay-ui
  - quay-obo
  - quay-unknown-aud
EOF
cp "${SHARED_DIR}/quay-auth-config.yaml" "${ARTIFACT_DIR}/quay-auth-config.yaml" || true
echo "Quay auth fragment written; Keycloak at ${KEYCLOAK_URL}"
