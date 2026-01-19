#!/bin/bash

set -e
set -u
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function setup_keycloak () {
    oc create ns keycloak
    KC_BOOTSTRAP_ADMIN_USERNAME="admin-$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 6 | head -n 1 || true)"
    KC_BOOTSTRAP_ADMIN_PASSWORD="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)"
    # For the "sed":
    # 1. For now, the DB pod's data isn't configured persistent. If the DB pod is restarted, the keycloak pod will have problem.
    # So, we do not use DB in keycloak by removing the KC_DB* env vars. Keycloak pod will use "postStart" for data.
    # 2. We don't use multiple keycloak pods given no persistent data, otherwise the different keycloak instances will have
    # inconsistent trust data when issuing id_token, which will cause oc commands on behalf of the logged in keycloak user fail
    # if the id_token issuing traffic is from keycloak instance 1 while the id_token validation traffic may go to keycloak instance 2
    curl -sS https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/refs/heads/main/kubernetes/keycloak.yaml \
        | sed -e "/- name: .*KC_DB/, +1 d" -e "s/replicas: .*/replicas: 1/" | oc create -n keycloak -f -
    oc delete deployment/postgres -n keycloak --ignore-not-found
    oc set env sts/keycloak KC_BOOTSTRAP_ADMIN_USERNAME=$KC_BOOTSTRAP_ADMIN_USERNAME KC_BOOTSTRAP_ADMIN_PASSWORD=$KC_BOOTSTRAP_ADMIN_PASSWORD -n keycloak

    oc create route edge keycloak --service=keycloak -n keycloak
    KEYCLOAK_HOST=https://$(oc get -n keycloak route keycloak --template='{{ .spec.host }}')
    # If the cluster has control plane nodes, schedule the keycloak server onto those nodes where the keycloak
    # server pods are less likely frequently drained/restarted in case worker nodes are spot instances
    if oc get node | grep control-plane > /dev/null; then
        oc patch sts/keycloak -n keycloak -p="
spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ''
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
"
    fi

    prepare_keycloak_client_files
    prepare_keycloak_user_data
    prepare_keycloak_setup_script

    oc create configmap setup-script -n keycloak --from-file=/tmp/.keycloak/client-oc-cli-test.json \
        --from-file=/tmp/.keycloak/client-console-test.json --from-file=/tmp/.keycloak/groupmapper-for-clients.json \
        --from-literal=testusers="$users" --from-file=/tmp/.keycloak/setup-script.sh
    oc set volumes sts/keycloak -n keycloak --add --type=configmap --configmap-name=setup-script --mount-path=/tmp/.keycloak

    # In future, investigate how to use PVC instead of "postStart"
    oc patch sts/keycloak -n keycloak -p="
spec:
  template:
    spec:
      containers:
      - name: keycloak
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/bash
              - -c
              - |
                # suggested by https://kubernetes.io/docs/tasks/configure-pod-container/attach-handler-lifecycle-event/
                bash /tmp/.keycloak/setup-script.sh &> /tmp/postStart.log || true
"

    echo "Wait the Keycloak server to be running up ..."
    # Due to above oc set/patch, the pod's revisions might be changing quickly
    # It is observed that using simple "sleep 2m; oc wait ..." is not enough, after which the pod might still be Running in
    # an outdated revision and then transit to Terminating again to roll out to the final revision. So using a loop to check
    sleep 60
    timeout 10m bash -c 'while true; do
        if oc wait pod/keycloak-0 --for=condition=Ready -n keycloak --timeout=400s; then
            oc get po -n keycloak -L controller-revision-hash
	    R1=$(oc get sts/keycloak -n keycloak -o=jsonpath="{.status.updateRevision}")
	    R2=$(oc get po/keycloak-0 -n keycloak -o=jsonpath="{.metadata.labels.controller-revision-hash}")
            if [ "$R2" == "$R1" ]; then
                break
	    fi
            sleep 20
        fi
    done
    ' || {  echo "Timeout waiting the Keycloak server to be running up"; exit 1; }

    oc get po -n keycloak -L controller-revision-hash
    echo "Keycloak setup logs:"
    oc rsh -n keycloak sts/keycloak cat /tmp/postStart.log |& tee /tmp/postStart.log
    if ! grep -q "Keycloak setup done" /tmp/postStart.log; then
        echo "Keycloak setup not done!"
        exit 1
    fi

    mkdir -p /tmp/router-ca
    oc extract cm/default-ingress-cert -n openshift-config-managed --to=/tmp/router-ca --confirm
    /bin/cp /tmp/router-ca/ca-bundle.crt "$SHARED_DIR"/oidcProviders-ca.crt # will be used in go-lang e2e cases
    # Currently we use the router-CA-signed certificates for the keycloak server
    if curl -sSI --cacert /tmp/router-ca/ca-bundle.crt $KEYCLOAK_HOST/realms/master/.well-known/openid-configuration | grep -Eq 'HTTP/[^ ]+ 200'; then
        echo "The keycloak host is accessible!"
    else
        echo "The keycloak host is inaccessible!"
        exit 1
    fi

    # The tested / supported version will need to be filled in the tested configurations google doc for each OCP new release
    oc rsh -n keycloak sts/keycloak cat /opt/keycloak/version.txt

    ISSUER_URL=$KEYCLOAK_HOST/realms/master
    CONSOLE_CLIENT_ID=console-test
    # CONSOLE_CLIENT_SECRET_VALUE is set in previous function
    CONSOLE_CLIENT_SECRET_NAME=console-secret
    CLI_CLIENT_ID=oc-cli-test
    AUDIENCE_1=$CONSOLE_CLIENT_ID
    AUDIENCE_2=$CLI_CLIENT_ID
    oc create secret generic $CONSOLE_CLIENT_SECRET_NAME --from-literal=clientSecret=$CONSOLE_CLIENT_SECRET_VALUE --dry-run=client -o yaml > "$SHARED_DIR"/oidcProviders-secret-configmap.yaml
    echo "---" >> "$SHARED_DIR"/oidcProviders-secret-configmap.yaml
    oc create configmap keycloak-oidc-ca --from-file=ca-bundle.crt=/tmp/router-ca/ca-bundle.crt --dry-run=client -o yaml >> "$SHARED_DIR"/oidcProviders-secret-configmap.yaml
    # Spaces or symbol characters in below "name" should work, in case of similar bug OCPBUGS-44099 in old IDP area
    # Note, the value examples (e.g. extra's values) used here may be tested and referenced otherwhere.
    # So, when modifying them, search and modify otherwhere too
    cat > "$SHARED_DIR"/oidcProviders.json << EOF
{
  "oidcProviders": [
    {
      "claimMappings": {
        "groups": {"claim": "groups", "prefix": "oidc-groups-test:"},
        "username": {"claim": "email", "prefixPolicy": "Prefix", "prefix": {"prefixString": "oidc-user-test:"}},
        "extra": [
          {"key": "extratest.openshift.com/foo", "valueExpression": "claims.email"},
          {"key": "extratest.openshift.com/bar", "valueExpression": "\"extra-test-mark\""}
        ],
        "uid": {"expression": "\"testuid-\" + claims.sub + \"-uidtest\""}
      },
      "issuer": {
        "issuerURL": "$ISSUER_URL", "audiences": ["$AUDIENCE_1", "$AUDIENCE_2"],
        "issuerCertificateAuthority": {"name": "keycloak-oidc-ca"}
      },
      "name": "keycloak oidc server",
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

    # Grant external oidc users "self-provisioner" so that they'll be able to run oc new-project in test cases
    # This should be done after step "idp-external-oidc" where external oidc auth gets configured
    # But no harm to do it here in advance considering the group info is determined in current step of script
    oc adm policy add-cluster-role-to-group self-provisioner 'oidc-groups-test:keycloak-testgroup-1'

}

function prepare_keycloak_setup_script () {
    # Use single quotes on EOF so that the variables are not expanded
    cat > /tmp/.keycloak/setup-script.sh << 'EOF'
set -euo pipefail
export PATH=$PATH:/opt/keycloak/bin
echo "We need to wait the Keycloak server to be running up ..."
timeout 5m bash -c 'while true; do
    # Though securely exposed outside via edge route, it is exposed insecurely inside the pod. In future, may switch to secure https server
    kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
        --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" --config=/tmp/.keycloak-kcadm.config
    if [ "$?" == "0" ] ; then
        break
    fi
    sleep 10
    done
' || {  echo "Timeout waiting the Keycloak server to be running up"; exit 1; }
# We set the realm's ssoSessionIdleTimeout a bit long so that the session of retrieved id_token / refresh_token
# in a test case will not expire early. This is helpful if some test case's execution time is long where the
# tokens will keep valid during a long test case execution.
echo "Setting realms/master ssoSessionIdleTimeout"
kcadm.sh update realms/master -s ssoSessionIdleTimeout=7200 --config=/tmp/.keycloak-kcadm.config

echo "Creating clients"
kcadm.sh create clients -r master --config=/tmp/.keycloak-kcadm.config -f /tmp/.keycloak/client-oc-cli-test.json &> /tmp/cmd_output
CLIENT_OC_CLI_TEST_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")
kcadm.sh create clients -r master --config=/tmp/.keycloak-kcadm.config -f /tmp/.keycloak/client-console-test.json &> /tmp/cmd_output
CLIENT_CONSOLE_TEST_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")

echo "Creating group mapper for clients"
kcadm.sh create clients/"$CLIENT_OC_CLI_TEST_ID"/protocol-mappers/models \
    -f /tmp/.keycloak/groupmapper-for-clients.json --config=/tmp/.keycloak-kcadm.config
kcadm.sh create clients/"$CLIENT_CONSOLE_TEST_ID"/protocol-mappers/models \
    -f /tmp/.keycloak/groupmapper-for-clients.json --config=/tmp/.keycloak-kcadm.config

echo "Creating group"
kcadm.sh create groups -r master -s name="keycloak-testgroup-1" --config=/tmp/.keycloak-kcadm.config &> /tmp/cmd_output
TEST_GROUP_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")
IFS=','
echo "Creating users"
for i in $(cat /tmp/.keycloak/testusers)
do
    TEST_USER_NAME="$(cut -d ':' -f 1 <<< $i)"
    TEST_USER_PASSWORD="$(cut -d ':' -f 2 <<< $i)"
    kcadm.sh create users -r master -s username="$TEST_USER_NAME" -s enabled=true -s firstName="$TEST_USER_NAME" -s lastName=KC \
        -s email="$TEST_USER_NAME"@example.com -s emailVerified=true --config=/tmp/.keycloak-kcadm.config &> /tmp/cmd_output
    # The output looks like: Created new user with id '7afe5557-c21c-4658-84be-f28460c838c3'
    TEST_USER_ID=$(grep -Eo "'.+'" /tmp/cmd_output | grep -Eo "[^']+")
    kcadm.sh set-password -r master --username "$TEST_USER_NAME" --new-password "$TEST_USER_PASSWORD" \
        --temporary=false --config=/tmp/.keycloak-kcadm.config

    # Add the user to the group
    kcadm.sh update users/"$TEST_USER_ID"/groups/"$TEST_GROUP_ID" -r master -s realm=master -s userId="$TEST_USER_ID" \
        -s groupId="$TEST_GROUP_ID" --no-merge --config=/tmp/.keycloak-kcadm.config
done
echo "Checking group membership"
kcadm.sh get groups/"$TEST_GROUP_ID"/members --fields username --format csv --config=/tmp/.keycloak-kcadm.config | grep -q "$TEST_USER_NAME"
echo "Keycloak setup done!"
EOF
}

function prepare_keycloak_client_files () {
    mkdir -p /tmp/.keycloak
    # The client.session.idle.timeout decides the refresh_token lifespan of the client.
    # We set it a bit long so that the refresh_token in a test case will not expire early if some test
    # case's execution time is long. The id_token can be therefore refreshed for long. The lifespan of
    # oc command's token cache will therefore be long enough for a long-duration test case.
    # However, setting client.session.idle.timeout is not enough. The realm's ssoSessionIdleTimeout must
    # be also set (See the `kcadm.sh update realms/master ...` line).

    # The id_token lifespan defaults to 60 seconds. This could bring problem in e2e tests when the
    # refresh_token refreshes the id_token not timely enough due to network delay issue. In such
    # situation, a test can sometimes fail with "You must be logged in to the server (Unauthorized)".
    # So setting the id_token lifespan a bit larger, which is decided by the "access.token.lifespan" field.
    cat > /tmp/.keycloak/client-oc-cli-test.json << EOF
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
    "access.token.lifespan" : "150",
    "client.session.idle.timeout" : "7200"
  }
}
EOF

    CLUSTER_CONSOLE=$(oc whoami --show-console)
    CONSOLE_CLIENT_SECRET_VALUE=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 32 | head -n 1 || true)
    cat > /tmp/.keycloak/client-console-test.json << EOF
{
  "clientId" : "console-test",
  "enabled" : true,
  "secret" : "$CONSOLE_CLIENT_SECRET_VALUE",
  "redirectUris" : [ "$CLUSTER_CONSOLE/auth/callback" ],
  "webOrigins" : [ "$CLUSTER_CONSOLE" ],
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
    "access.token.lifespan" : "150",
    "client.session.idle.timeout" : "7200"
  }
}
EOF

    cat > /tmp/.keycloak/groupmapper-for-clients.json << EOF
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
EOF
}

function prepare_keycloak_user_data () {
    # prepare normal test users
    users=""

    for i in $(seq 1 50);
    do
        username="keycloak-testuser-${i}"
        password=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
        users+="${username}:${password},"
    done
    # The $users will be mounted into keycloak pods and the real test users will be created there
    users=${users::-1}

    # store users in a shared file
    if [ -f "${SHARED_DIR}/runtime_env" ] ; then
        source "${SHARED_DIR}/runtime_env"
    fi
    runtime_env="${SHARED_DIR}/runtime_env"

    # The test users will be consumed in test cases
    cat << EOF >> "${runtime_env}"
export KEYCLOAK_ISSUER="${KEYCLOAK_HOST}/realms/master"
export KEYCLOAK_TEST_USERS="${users}"
export KEYCLOAK_CLI_CLIENT_ID="oc-cli-test"
export CONSOLE_CLIENT_SECRET_VALUE="${CONSOLE_CLIENT_SECRET_VALUE}"
export KEYCLOAK_CA_BUNDLE_FILE=$SHARED_DIR/oidcProviders-ca.crt
# it is also defined in function setup_keycloak
export CONSOLE_CLIENT_ID="console-test"
EOF

}

# Main script execution with error handling
set_proxy
setup_keycloak
