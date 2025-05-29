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
    KEYCLOAK_ADMIN_TEST_USER="admin-$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 6 | head -n 1 || true)"
    KEYCLOAK_ADMIN_TEST_PASSWORD="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)"
    oc process -n keycloak -f https://raw.githubusercontent.com/keycloak/keycloak-quickstarts/latest/openshift/keycloak.yaml \
        -p KEYCLOAK_ADMIN="$KEYCLOAK_ADMIN_TEST_USER" -p KEYCLOAK_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_TEST_PASSWORD" \
        -p NAMESPACE=keycloak \
        | sed -e 's/KEYCLOAK_ADMIN_PASSWORD/KC_BOOTSTRAP_ADMIN_PASSWORD/g' -e 's/KEYCLOAK_ADMIN\b/KC_BOOTSTRAP_ADMIN_USERNAME/g' \
        | oc create -n keycloak -f -
    KEYCLOAK_HOST=https://$(oc get -n keycloak route keycloak --template='{{ .spec.host }}')

    # Once https://github.com/keycloak/keycloak-quickstarts/pull/682 merges, change "dc/keycloak" to "deployment/keycloak"
    # KC_HOSTNAME is needed for keycloak 26.0.0+ ( https://github.com/keycloak/keycloak-quickstarts/issues/641#issuecomment-2659164943 )
    oc set env -n keycloak dc/keycloak -e KC_HOSTNAME=$KEYCLOAK_HOST

    # If the cluster has control plane nodes, schedule the keycloak server onto those nodes where the keycloak
    # server pods are less likely frequently drained/restarted in case worker nodes are spot instances
    if oc get node -l node-role.kubernetes.io/control-plane | grep -q Ready; then
        oc patch dc/keycloak -n keycloak -p="
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
    oc set volumes dc/keycloak -n keycloak --add --type=configmap --configmap-name=setup-script --mount-path=/tmp/.keycloak

    # In future, investigate how to use PVC instead of "postStart"
    oc patch dc/keycloak -n keycloak -p="
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
    if ! oc wait dc/keycloak --for=condition=Available -n keycloak --timeout=400s; then
        oc get po -n keycloak
        exit 1
    fi
    oc get po -n keycloak
    echo "Keycloak setup logs:"
    oc rsh -n keycloak dc/keycloak cat /tmp/postStart.log |& tee /tmp/postStart.log
    if ! grep -q "Keycloak setup done" /tmp/postStart.log; then
        echo "Keycloak setup not done!"
        exit 1
    fi

    mkdir -p /tmp/router-ca
    oc extract cm/default-ingress-cert -n openshift-config-managed --to=/tmp/router-ca --confirm
    /bin/cp /tmp/router-ca/ca-bundle.crt "$SHARED_DIR"/oidcProviders-ca.crt # will be used in go-lang e2e cases
    # Currently we use the router-CA-signed certificates for the keycloak server
    curl -sSI --cacert /tmp/router-ca/ca-bundle.crt $KEYCLOAK_HOST/realms/master/.well-known/openid-configuration | head -n 1 | grep -q 'HTTP/1.1 200 OK'

    # The tested / supported version will need to be filled in the tested configurations google doc for each OCP new release
    oc rsh -n keycloak dc/keycloak cat /opt/keycloak/version.txt

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
    cat > "$SHARED_DIR"/oidcProviders.json << EOF
{
  "oidcProviders": [
    {
      "claimMappings": {
        "groups": {"claim": "groups", "prefix": "oidc-groups-test:"},
        "username": {"claim": "email", "prefixPolicy": "Prefix", "prefix": {"prefixString": "oidc-user-test:"}}
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
EOF

}

# Main script execution with error handling
set_proxy
setup_keycloak
