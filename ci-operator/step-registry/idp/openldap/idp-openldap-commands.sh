#!/bin/bash

set -e
set -u
set -o pipefail

function check_if_hypershift_env () {
    if [ -f "${SHARED_DIR}/nested_kubeconfig" ]; then
        IS_HYPERSHIFT_ENV="yes"
    else
        # We must set IS_HYPERSHIFT_ENV="no" otherwise OCP CI will fail because this script sets "set -u".
        IS_HYPERSHIFT_ENV="no"
        return 0
    fi
    MC_KUBECONFIG_FILE="${SHARED_DIR}/hs-mc.kubeconfig"
    if [ -f "${MC_KUBECONFIG_FILE}" ]; then
        export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
        _jsonpath="{.items[?(@.metadata.name==\"$(cat ${SHARED_DIR}/cluster-name)\")].metadata.namespace}"
        HYPERSHIFT_NAMESPACE=$(oc get hostedclusters -A -ojsonpath="$_jsonpath")
    elif [ -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
        export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
    else
        echo "This idp-openldap step is being run as a day-2 operation for a HyperShift guest cluster. We need the kubeconfig of management cluster, but it does not exist!"
        exit 1
    fi

    count=$(oc get hostedclusters --no-headers --ignore-not-found -n "$HYPERSHIFT_NAMESPACE" | wc -l)
    echo "hostedcluster count: $count"
    if [ "$count" -lt 1 ]  ; then
        echo "namespace clusters don't have hostedcluster"
        exit 1
    fi
    # Limitation: we always & only select the first hostedcluster to add idp-openldap. "
    cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
}

function set_common_variables () {
    if [ "$IS_HYPERSHIFT_ENV" == "yes" ]; then
        # In some HyperShift CI, the namespace of hostedcluster is local-cluster instead of clusters.
        MIDDLE_NAMESPACE="$HYPERSHIFT_NAMESPACE"
        TARGET_RESOURCE="hostedcluster/$cluster_name -n $MIDDLE_NAMESPACE"
        OAUTH_NAMESPACE="$MIDDLE_NAMESPACE-$cluster_name"
        IDP_FIELD=".spec.configuration.oauth.identityProviders"
    else
        MIDDLE_NAMESPACE="openshift-config"
        TARGET_RESOURCE="oauth/cluster"
        OAUTH_NAMESPACE="openshift-authentication"
        IDP_FIELD=".spec.identityProviders"
    fi
}

# Function to set the proxy, if applicable
function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting the proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy setting."
    fi
}

# Check if any IDP is already configured
function check_idp() {
    # Check if runtime_env exists and then check if $USERS is not empty
    if [ -f "${SHARED_DIR}/runtime_env" ]; then
        source "${SHARED_DIR}/runtime_env"
    else
        echo "runtime_env does not exist, continuing checking..."
        USERS=""
    fi

    # Fetch the detailed identityProviders configuration if any
    current_idp_config=$(oc get $TARGET_RESOURCE -o jsonpath='{range '$IDP_FIELD'[*]}{.name}{" "}{.type}{"\n"}{end}')

    if [ -n "$current_idp_config" ] && [ "$current_idp_config" != "null" ] && [ -n "$USERS" ]; then
        echo -e "Skipping addition of new OpenLDAP IDP because already configured IDP as below:\n$current_idp_config"
        exit 0
    fi
}

# Function to generate random passwords and update the temporary ldif file
function update_ldif() {
    # Create a temporary ldif file
    temp_ldif=$(mktemp)

    # Initial content for the temporary ldif file
    echo "dn: ou=rfc2307,dc=example,dc=com
objectClass: organizationalUnit
ou: rfc2307
description: RFC2307-style Entries

dn: ou=groups,ou=rfc2307,dc=example,dc=com
objectClass: organizationalUnit
ou: groups
description: User Groups

dn: ou=people,ou=rfc2307,dc=example,dc=com
objectClass: organizationalUnit
ou: people
description: Users
" > "$temp_ldif"

    # Initialize users variable
    users=""
    echo "Generating random passwords and updating temporary ldif file"
    for i in $(seq 1 50); do
        username="Person${i}"
        password=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
        users+="${username}:${password},"

        # Append user entry directly to the temporary ldif file
        echo "
dn: cn=$username,ou=people,ou=rfc2307,dc=example,dc=com
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
sn: Smith
cn: $username
displayName: ${username}smith
mail: ${username}smith@example.com
userPassword: $password
" >> "$temp_ldif"
    done

    # Optionally, you can output the path of the temporary file
    echo "Updated ldif file is located at: $temp_ldif"
}

function configure_openldap() {
    echo "Configuring OpenLDAP in OpenShift"
    oc create ns ldap

    echo "Creating a secret from the updated temporary init.ldif file"
    oc create secret generic ldap-init-ldif --from-file=init.ldif="$temp_ldif" -n ldap
    oc adm policy add-scc-to-user anyuid -z default -n ldap

    #Set ldap root password Secret
    LDAP_SECRET=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
    oc create secret generic ldap-admin-password --from-literal=OPENLDAP_ROOT_PASSWORD="${LDAP_SECRET}" -n ldap

    # Define the LDAP deployment
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ldap
  namespace: ldap
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ldap
  template:
    metadata:
      labels:
        app: ldap
    spec:
      containers:
      - name: ldap
        image: quay.io/openshifttest/ldap:multiarch
        env:
        - name: OPENLDAP_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ldap-admin-password
              key: OPENLDAP_ROOT_PASSWORD
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/sh
              - -c
              - |
                sleep 120
                # Then run ldapadd command
                ldapadd -x -H 'ldap://127.0.0.1:389' -D 'cn=Manager,dc=example,dc=com' -w \$OPENLDAP_ROOT_PASSWORD -f /tmp/init.ldif
        volumeMounts:
        - name: init-ldif-volume
          mountPath: /tmp
      volumes:
      - name: init-ldif-volume
        secret:
          secretName: ldap-init-ldif
---
apiVersion: v1
kind: Service
metadata:
  name: ldap
  namespace: ldap
spec:
  selector:
    app: ldap
  ports:
  - protocol: TCP
    port: 389
    targetPort: 389
EOF

    # Wait for LDAP pod to be running and ready
    echo "Checking for LDAP pod to be running and ready"
    count=0
    max_attempts=10
    while :; do
        pod_status=$(oc get pods -n ldap --no-headers | grep ldap)
        if [[ $pod_status == *"1/1"*"Running"* ]]; then
            echo "LDAP pod is running and ready."
            break
        fi

        echo "Waiting for LDAP pod to be running and ready..."
        sleep 30
        ((count++))

        if [[ $count -ge $max_attempts ]]; then
            echo "Timeout waiting for LDAP pod to be running and ready. Exiting."
            return 1
        fi
    done
}

# Function to configure the identity provider in OpenShift
function configure_identity_provider() {
    echo "Configuring OpenShift identity provider with OpenLDAP"

    # Create network policy to allow access from hypershift namespace to ldap namespace
    if [ "$IS_HYPERSHIFT_ENV" == "yes" ]; then
        cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress-egress
  namespace: $OAUTH_NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - {}
  egress:
  - {}
EOF
    fi


    # Current generation
    gen=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.metadata.generation}')

    # Prepare the new LDAP identity provider configuration
    oauth_file_src=/tmp/cucushift-oauth-src.yaml
    oauth_file_dst=/tmp/cucushift-oauth-dst.yaml
    # Don't quote the $TARGET_RESOURCE variable because it may include spaces
    oc get $TARGET_RESOURCE -o json > "${oauth_file_src}"
    jq $IDP_FIELD' += [{"ldap":{"attributes":{"email":["mail"],"id":["dn"],"name":["cn"],"preferredUsername":["cn"]},"bindDN":"","bindPassword":{"name":""},"insecure":true,"url":"ldap://ldap.ldap.svc:389/ou=people,ou=rfc2307,dc=example,dc=com?cn"},"mappingMethod":"claim","name":"ldapidp","type":"LDAP"}]' "${oauth_file_src}" > "${oauth_file_dst}"
    oc replace -f "${oauth_file_dst}"

    # Wait for oauth-openshift to rollout
    wait_auth=true
    expected_replicas=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.spec.replicas}')
    while $wait_auth; do
        available_replicas=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.status.availableReplicas}')
        new_gen=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.metadata.generation}')
        if [[ $expected_replicas == "$available_replicas" && $((new_gen)) -gt $((gen)) ]]; then
            wait_auth=false
        else
            sleep 10
        fi
    done

    # store users in a shared file
    if [ -f "${SHARED_DIR}/runtime_env" ] ; then
        source "${SHARED_DIR}/runtime_env"
    fi
    runtime_env=${SHARED_DIR}/runtime_env
    users=${users::-1}

    cat <<EOF >>"${runtime_env}"
export USERS=${users}
EOF
}

# Error handling function
function handle_error() {
    echo "Error occurred in $1"
    exit 1
}

# Check cluster type and skip steps if necessary
if [ -f "${SHARED_DIR}/cluster-type" ] ; then
    CLUSTER_TYPE=$(cat "${SHARED_DIR}/cluster-type")
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]]; then
        echo "Skip the step. The managed clusters generate the testing accounts by themselves"
        exit 0
    fi
fi

# Main script execution with error handling
set_proxy || handle_error "set_proxy"
check_if_hypershift_env || handle_error "check_if_hypershift_env"
set_common_variables || handle_error "set_common_variables"
check_idp || handle_error "check_idp"
update_ldif || handle_error "update_ldif"
configure_openldap || handle_error "configure_openldap"
configure_identity_provider || handle_error "configure_identity_provider"

# Cleanup temporary files
echo "Cleaning up temporary files"
rm -f "$temp_ldif"
