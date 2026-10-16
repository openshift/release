#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy a seeded OpenLDAP into the Quay namespace for the Playwright LDAP suite
# (TEST_USERS_LDAP in web/playwright/global-setup.ts, team-sync-ldap.spec.ts).
# Handles the LDAP admin password: never enable tracing (set -x) in this script.

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_NS="${QUAYNAMESPACE}"
LDAP_SUFFIX="dc=example,dc=com"
LDAP_ROOT_DN="cn=Manager,${LDAP_SUFFIX}"
LDAP_SVC_URI="ldap://openldap.${QUAY_NS}.svc:389"
LDAP_GROUP_DN="cn=test_ldap_group,ou=groups,${LDAP_SUFFIX}"

# Remove any stale fragment so a failed retry never leaves Quay pointed at an
# IdP whose preflight did not pass in this run.
rm -f "${SHARED_DIR}/quay-auth-config.yaml"

oc get namespace "${QUAY_NS}" >/dev/null 2>&1 || oc create namespace "${QUAY_NS}"

# run-openldap.sh only applies OPENLDAP_ROOT_PASSWORD when running as root.
oc create serviceaccount openldap -n "${QUAY_NS}" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z openldap -n "${QUAY_NS}"

# Reuse an existing secret on retry: slapd keeps the password it first started with.
if ! oc get secret openldap -n "${QUAY_NS}" >/dev/null 2>&1; then
  oc create secret generic openldap -n "${QUAY_NS}" \
    --from-literal=OPENLDAP_ROOT_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr '+/' 'xy')"
fi

echo "Deploying OpenLDAP (${OPENLDAP_IMAGE}) into ${QUAY_NS}..."
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openldap
  namespace: ${QUAY_NS}
  labels:
    app: openldap
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openldap
  template:
    metadata:
      labels:
        app: openldap
    spec:
      serviceAccountName: openldap
      containers:
      - name: openldap
        image: ${OPENLDAP_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: OPENLDAP_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: openldap
              key: OPENLDAP_ROOT_PASSWORD
        ports:
        - name: ldap
          containerPort: 389
        # First boot runs a temporary slapd to configure itself, then touches
        # CONFIGURED and execs the real one; port 389 alone is not ready.
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - test -f /etc/openldap/CONFIGURED && ldapsearch -x -H ldap://127.0.0.1:389 -b "${LDAP_SUFFIX}" -s base dn
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: openldap
  namespace: ${QUAY_NS}
  labels:
    app: openldap
spec:
  selector:
    app: openldap
  ports:
  - name: ldap
    port: 389
    targetPort: 389
EOF

echo "Waiting for OpenLDAP rollout..."
if ! oc rollout status deployment/openldap -n "${QUAY_NS}" --timeout=5m; then
  oc get pods -n "${QUAY_NS}" -l app=openldap -o wide >&2 || true
  oc describe pods -n "${QUAY_NS}" -l app=openldap >&2 || true
  exit 1
fi

# Seed the fixture users. employeeType carries the group DN because Quay's team
# sync searches (LDAP_MEMBEROF_ATTR=<group dn>) and memberOf is overlay-managed.
# The single-quoted sh -c expands the root password inside the pod only.
echo "Seeding LDAP fixture users..."
seed_out=$(oc exec -i -n "${QUAY_NS}" deploy/openldap -- sh -c \
  'ldapadd -c -x -H ldap://127.0.0.1:389 -D "$1" -w "$OPENLDAP_ROOT_PASSWORD"' sh "${LDAP_ROOT_DN}" 2>&1 <<EOF
dn: ou=users,${LDAP_SUFFIX}
objectClass: organizationalUnit
ou: users

dn: ou=groups,${LDAP_SUFFIX}
objectClass: organizationalUnit
ou: groups

dn: uid=admin_ldap,ou=users,${LDAP_SUFFIX}
objectClass: inetOrgPerson
uid: admin_ldap
cn: Admin Ldap
sn: Ldap
mail: admin_ldap@example.com
userPassword: password
employeeType: ${LDAP_GROUP_DN}

dn: uid=testuser_ldap,ou=users,${LDAP_SUFFIX}
objectClass: inetOrgPerson
uid: testuser_ldap
cn: Testuser Ldap
sn: Ldap
mail: testuser_ldap@example.com
userPassword: password
employeeType: ${LDAP_GROUP_DN}

dn: uid=readonly_ldap,ou=users,${LDAP_SUFFIX}
objectClass: inetOrgPerson
uid: readonly_ldap
cn: Readonly Ldap
sn: Ldap
mail: readonly_ldap@example.com
userPassword: password

dn: ${LDAP_GROUP_DN}
objectClass: groupOfNames
cn: test_ldap_group
member: uid=admin_ldap,ou=users,${LDAP_SUFFIX}
member: uid=testuser_ldap,ou=users,${LDAP_SUFFIX}
EOF
) || true
echo "${seed_out}"
# Entries left by a previous attempt are fine; any other add error is not.
if grep '^ldap_' <<<"${seed_out}" | grep -qv 'Already exists (68)'; then
  echo "ERROR: seeding OpenLDAP failed" >&2
  exit 1
fi

# Preflight through the Service URI Quay will use.
echo "Preflight: binding as testuser_ldap via ${LDAP_SVC_URI}..."
oc exec -n "${QUAY_NS}" deploy/openldap -- ldapwhoami -x -H "${LDAP_SVC_URI}" \
  -D "uid=testuser_ldap,ou=users,${LDAP_SUFFIX}" -w password

echo "Preflight: searching (employeeType=${LDAP_GROUP_DN}) as the admin DN..."
members=$(oc exec -n "${QUAY_NS}" deploy/openldap -- sh -c \
  'ldapsearch -x -LLL -H "$1" -D "$2" -w "$OPENLDAP_ROOT_PASSWORD" -b "$3" "(employeeType=$4)" dn' \
  sh "${LDAP_SVC_URI}" "${LDAP_ROOT_DN}" "ou=users,${LDAP_SUFFIX}" "${LDAP_GROUP_DN}" | grep '^dn:' | sort || true)
expected=$(printf 'dn: uid=%s,ou=users,%s\n' admin_ldap "${LDAP_SUFFIX}" testuser_ldap "${LDAP_SUFFIX}")
if [[ "${members}" != "${expected}" ]]; then
  echo "ERROR: team sync group search returned:" >&2
  echo "${members:-<nothing>}" >&2
  exit 1
fi
echo "${members}"

# The seed add tolerates errors, so confirm the entries the searches above cannot see.
for dn in "uid=readonly_ldap,ou=users,${LDAP_SUFFIX}" "${LDAP_GROUP_DN}"; do
  echo "Preflight: checking ${dn} exists..."
  oc exec -n "${QUAY_NS}" deploy/openldap -- sh -c \
    'ldapsearch -x -LLL -H "$1" -D "$2" -w "$OPENLDAP_ROOT_PASSWORD" -b "$3" -s base dn' \
    sh "${LDAP_SVC_URI}" "${LDAP_ROOT_DN}" "${dn}"
done

LDAP_ADMIN_PASSWD=$(oc get secret openldap -n "${QUAY_NS}" -o jsonpath='{.data.OPENLDAP_ROOT_PASSWORD}' | base64 -d)

# Built with yq and strenv so the password is quoted safely and never in argv.
LDAP_ADMIN_PASSWD="${LDAP_ADMIN_PASSWD}" LDAP_SVC_URI="${LDAP_SVC_URI}" LDAP_ROOT_DN="${LDAP_ROOT_DN}" yq -n '
  .AUTHENTICATION_TYPE = "LDAP" |
  .FEATURE_TEAM_SYNCING = true |
  .FEATURE_USER_INITIALIZE = false |
  .LDAP_URI = strenv(LDAP_SVC_URI) |
  .LDAP_ADMIN_DN = strenv(LDAP_ROOT_DN) |
  .LDAP_ADMIN_PASSWD = strenv(LDAP_ADMIN_PASSWD) |
  .LDAP_ALLOW_INSECURE_FALLBACK = true |
  .LDAP_BASE_DN = ["dc=example", "dc=com"] |
  .LDAP_USER_RDN = ["ou=users"] |
  .LDAP_UID_ATTR = "uid" |
  .LDAP_EMAIL_ATTR = "mail" |
  .LDAP_MEMBEROF_ATTR = "employeeType" |
  .SUPER_USERS = ["admin_ldap"] |
  .GLOBAL_READONLY_SUPER_USERS = ["readonly_ldap"]
' > "${SHARED_DIR}/quay-auth-config.yaml"

yq e '.LDAP_ADMIN_PASSWD = "REDACTED"' "${SHARED_DIR}/quay-auth-config.yaml" > "${ARTIFACT_DIR}/quay-auth-config.yaml" || true
echo "Wrote ${SHARED_DIR}/quay-auth-config.yaml (redacted copy in ARTIFACT_DIR)"
