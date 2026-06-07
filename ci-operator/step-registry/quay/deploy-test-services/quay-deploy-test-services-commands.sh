#!/bin/bash

set -euo pipefail
set -x

NAMESPACE="quay-enterprise"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# ---------------------------------------------------------------------------
# Keycloak (OIDC provider)
# ---------------------------------------------------------------------------

# Wildcard redirect URIs — Keycloak dev mode accepts any origin.
# The Quay route isn't known yet (deploy-quay-aws-s3 runs after this step).
cat > /tmp/quay-realm.json <<'REALM_EOF'
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
        "*"
      ],
      "webOrigins": ["+"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "+"
      }
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
REALM_EOF

oc -n "${NAMESPACE}" create configmap keycloak-realm \
  --from-file=quay-realm.json=/tmp/quay-realm.json \
  --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:26.2
        args: ["start-dev", "--import-realm"]
        env:
        - name: KC_HEALTH_ENABLED
          value: "true"
        - name: KC_HTTP_RELATIVE_PATH
          value: "/"
        - name: KEYCLOAK_ADMIN
          value: "admin"
        - name: KEYCLOAK_ADMIN_PASSWORD
          value: "admin"
        ports:
        - containerPort: 8080
        - containerPort: 9000
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 10
        volumeMounts:
        - name: realm
          mountPath: /opt/keycloak/data/import
      volumes:
      - name: realm
        configMap:
          name: keycloak-realm
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  selector:
    app: keycloak
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  to:
    kind: Service
    name: keycloak
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
EOF

# ---------------------------------------------------------------------------
# 389 Directory Server (LDAP)
# ---------------------------------------------------------------------------

# 389ds requires chown on system directories during initialization.
# The default restricted-v2 SCC blocks this, so we grant anyuid.
oc adm policy add-scc-to-user anyuid -z default -n "${NAMESPACE}"

cat > /tmp/base.ldif <<'LDIF_EOF'
dn: dc=example,dc=org
objectClass: top
objectClass: domain
dc: example

dn: ou=users,dc=example,dc=org
objectClass: organizationalUnit
ou: users

dn: uid=admin,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: admin
sn: Admin
givenName: Admin
cn: Admin User
displayName: Admin User
uidNumber: 10000
gidNumber: 10000
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/admin
mail: admin@example.com

dn: uid=user1,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: user1
sn: One
givenName: User
cn: User One
displayName: User One
uidNumber: 10001
gidNumber: 10001
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/user1
mail: user1@example.com

dn: uid=quayadmin,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: quayadmin
sn: Admin
givenName: Quay
cn: Quay Admin
displayName: Quay Admin
uidNumber: 10002
gidNumber: 10002
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/quayadmin
mail: quayadmin@example.com

dn: uid=readonly,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: readonly
sn: Only
givenName: Read
cn: Read Only
displayName: Read Only
uidNumber: 10003
gidNumber: 10003
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/readonly
mail: readonly@example.com

dn: uid=testuser,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: testuser
sn: User
givenName: Test
cn: Test User
displayName: Test User
uidNumber: 10004
gidNumber: 10004
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/testuser
mail: testuser@example.com

dn: uid=admin_ldap,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: quayUser
uid: admin_ldap
sn: Ldap
givenName: Admin
cn: Admin Ldap
displayName: Admin Ldap
uidNumber: 10005
gidNumber: 10005
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/admin_ldap
mail: admin_ldap@example.com
quayMemberOf: cn=test_ldap_group,ou=groups,dc=example,dc=org

dn: uid=testuser_ldap,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: quayUser
uid: testuser_ldap
sn: Ldap
givenName: Testuser
cn: Testuser Ldap
displayName: Testuser Ldap
uidNumber: 10006
gidNumber: 10006
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/testuser_ldap
mail: testuser_ldap@example.com
quayMemberOf: cn=test_ldap_group,ou=groups,dc=example,dc=org

dn: uid=readonly_ldap,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: readonly_ldap
sn: Ldap
givenName: Readonly
cn: Readonly Ldap
displayName: Readonly Ldap
uidNumber: 10007
gidNumber: 10007
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/readonly_ldap
mail: readonly_ldap@example.com

dn: ou=groups,dc=example,dc=org
objectClass: organizationalUnit
ou: groups

dn: cn=test_ldap_group,ou=groups,dc=example,dc=org
objectClass: groupOfUniqueNames
cn: test_ldap_group
uniqueMember: uid=testuser_ldap,ou=users,dc=example,dc=org
uniqueMember: uid=admin_ldap,ou=users,dc=example,dc=org
LDIF_EOF

cat > /tmp/init-389ds.sh <<'INIT_EOF'
#!/bin/bash
set -e

LDAPI_URI="ldapi://%2Fdata%2Frun%2Fslapd-localhost.socket"

echo "Waiting for 389 DS to start..."
timeout=60
while [ $timeout -gt 0 ]; do
    if ldapsearch -x -H ldap://localhost:3389 -b "" -s base &>/dev/null; then
        echo "389 DS is ready!"
        break
    fi
    sleep 1
    timeout=$((timeout - 1))
done

if [ $timeout -eq 0 ]; then
    echo "ERROR: 389 DS failed to start"
    exit 1
fi

if dsconf localhost backend suffix list | grep -q "dc=example,dc=org"; then
    echo "Backend already exists, skipping creation"
else
    echo "Creating backend for dc=example,dc=org..."
    dsconf localhost backend create --suffix "dc=example,dc=org" --be-name userroot
fi

echo "Adding custom schema for Quay group membership queries..."
ldapmodify -H "$LDAPI_URI" -Y EXTERNAL << 'SCHEMA_EOF'
dn: cn=schema
changetype: modify
add: attributeTypes
attributeTypes: ( 1.3.6.1.4.1.99999.1 NAME 'quayMemberOf' DESC 'Quay group membership reference' EQUALITY distinguishedNameMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.12 )
-
add: objectClasses
objectClasses: ( 1.3.6.1.4.1.99999.2 NAME 'quayUser' DESC 'Quay user auxiliary class' SUP top AUXILIARY MAY ( quayMemberOf ) )
SCHEMA_EOF

if ldapsearch -x -H ldap://localhost:3389 -D "cn=Directory Manager" -w "$DS_DM_PASSWORD" -b "ou=users,dc=example,dc=org" -s base &>/dev/null; then
    echo "Base DN already populated, skipping LDIF import"
else
    echo "Importing LDIF from /ldif-import/base.ldif..."
    ldapadd -c -H "$LDAPI_URI" -Y EXTERNAL -f /ldif-import/base.ldif
    echo "LDIF imported successfully!"
fi

echo "389 DS initialization complete!"
INIT_EOF

oc -n "${NAMESPACE}" create configmap ldap-config \
  --from-file=base.ldif=/tmp/base.ldif \
  --from-file=init-389ds.sh=/tmp/init-389ds.sh \
  --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ldap
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ldap
  template:
    metadata:
      labels:
        app: ldap
    spec:
      containers:
      - name: dirsrv
        image: docker.io/389ds/dirsrv:3.1
        env:
        - name: DS_SUFFIX_NAME
          value: "dc=example,dc=org"
        - name: DS_DM_PASSWORD
          value: "admin"
        ports:
        - containerPort: 3389
        - containerPort: 3636
        volumeMounts:
        - name: ldap-data
          mountPath: /ldif-import
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/bash
              - -c
              - "sleep 15 && bash /ldif-import/init-389ds.sh"
      volumes:
      - name: ldap-data
        configMap:
          name: ldap-config
          defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: ldap
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ldap
  ports:
  - name: ldap
    port: 3389
    targetPort: 3389
  - name: ldaps
    port: 3636
    targetPort: 3636
EOF

# ---------------------------------------------------------------------------
# Mailpit (email testing server)
# ---------------------------------------------------------------------------

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailpit
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailpit
  template:
    metadata:
      labels:
        app: mailpit
    spec:
      containers:
      - name: mailpit
        image: docker.io/axllent/mailpit:v1.30
        env:
        - name: MP_SMTP_AUTH_ACCEPT_ANY
          value: "true"
        - name: MP_SMTP_AUTH_ALLOW_INSECURE
          value: "true"
        ports:
        - containerPort: 1025
          name: smtp
        - containerPort: 8025
          name: http
        readinessProbe:
          httpGet:
            path: /api/v1/messages
            port: 8025
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit
  namespace: ${NAMESPACE}
spec:
  selector:
    app: mailpit
  ports:
  - name: smtp
    port: 1025
    targetPort: 1025
  - name: http
    port: 8025
    targetPort: 8025
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mailpit
  namespace: ${NAMESPACE}
spec:
  to:
    kind: Service
    name: mailpit
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
EOF

# ---------------------------------------------------------------------------
# Wait for all services to be ready
# ---------------------------------------------------------------------------

echo "Waiting for Keycloak to be ready..."
oc -n "${NAMESPACE}" rollout status deployment/keycloak --timeout=300s

echo "Waiting for LDAP to be ready..."
oc -n "${NAMESPACE}" rollout status deployment/ldap --timeout=300s

echo "Waiting for Mailpit to be ready..."
oc -n "${NAMESPACE}" rollout status deployment/mailpit --timeout=120s

# Wait for LDAP to be fully initialized (init script runs via postStart)
echo "Waiting for LDAP initialization to complete..."
LDAP_POD=$(oc -n "${NAMESPACE}" get pod -l app=ldap -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 60); do
  if oc -n "${NAMESPACE}" exec "${LDAP_POD}" -- \
    ldapsearch -x -H ldap://localhost:3389 -D "cn=Directory Manager" -w admin \
    -b "ou=users,dc=example,dc=org" -s base &>/dev/null; then
    echo "LDAP is initialized and accepting queries"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "ERROR: LDAP failed to initialize within 60 attempts" >&2
    oc -n "${NAMESPACE}" logs "${LDAP_POD}" > "${ARTIFACT_DIR}/ldap-pod.log" 2>&1 || true
    exit 1
  fi
  sleep 5
done

# Save Keycloak route for the test step (poll until route is admitted)
KEYCLOAK_ROUTE=""
for i in $(seq 1 30); do
  KEYCLOAK_ROUTE=$(oc -n "${NAMESPACE}" get route keycloak -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)
  [[ -n "${KEYCLOAK_ROUTE}" ]] && break
  sleep 2
done
if [[ -z "${KEYCLOAK_ROUTE}" ]]; then
  echo "ERROR: Could not determine Keycloak route" >&2
  exit 1
fi
echo "https://${KEYCLOAK_ROUTE}" > "${SHARED_DIR}/keycloak_route"
echo "Keycloak route: https://${KEYCLOAK_ROUTE}"

# Save Mailpit route
MAILPIT_ROUTE=""
for i in $(seq 1 30); do
  MAILPIT_ROUTE=$(oc -n "${NAMESPACE}" get route mailpit -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)
  [[ -n "${MAILPIT_ROUTE}" ]] && break
  sleep 2
done
if [[ -z "${MAILPIT_ROUTE}" ]]; then
  echo "ERROR: Could not determine Mailpit route" >&2
  exit 1
fi
echo "https://${MAILPIT_ROUTE}" > "${SHARED_DIR}/mailpit_route"
echo "Mailpit route: https://${MAILPIT_ROUTE}"

echo "All test services deployed successfully"
