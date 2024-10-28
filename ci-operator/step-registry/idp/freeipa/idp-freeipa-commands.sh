#!/bin/bash

set -e
set -u
set -o pipefail

# Function to set the proxy, if applicable
function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting the proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy setting."
    fi
}

function set_kubeconfig() {
    if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
        export KUBECONFIG=${SHARED_DIR}/kubeconfig
    fi
}

# Check if any IDP is already configured
function check_idp () {
    # Check if runtime_env exists and then check if $USERS is not empty
    if [ -f "${SHARED_DIR}/runtime_env" ]; then
        source "${SHARED_DIR}/runtime_env"
    else
        echo "runtime_env does not exist, continuing checking..."
        USERS=""
    fi

    # Fetch the detailed identityProviders configuration if any
    current_idp_config=$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{" "}{.type}{"\n"}{end}')

    if [ -n "$current_idp_config" ] && [ "$current_idp_config" != "null" ] && [ -n "$USERS" ]; then
        echo -e "Skipping addition of new FreeIPA IDP because already configured IDP as below:\n$current_idp_config"
        exit 0
    fi
}

# Function to generate random passwords and update the temporary user file
function set_users() {
    # Create a temporary ldif file
    temp_users=$(mktemp)

    # Initialize users variable
    users=""
    echo "Generating random passwords and updating temporary users file"
    for i in $(seq 1 51); do
        username="freeipa-testuser-${i}"
        password=$(</dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
        users+="${username}:${password},"

        # Append user entry directly to the temporary users file
        echo "${username},${password}" >> "$temp_users"
    done
    # Remove the last comma from the users variable
    users=${users%,}
}

function configure_freeipa() {
    echo "Configuring FreeIPA in OpenShift"
    oc create ns freeipa

    oc adm policy add-scc-to-user anyuid -z default -n freeipa

    echo "Creating a secret from the updated temporary users file"
    oc create secret generic freeipa-users-secret --from-file=users.txt="$temp_users" -n freeipa

    #Set freeipa root password Secret
    IPA_PASSWORD=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
    oc create secret generic freeipa --from-literal=PASSWORD="${IPA_PASSWORD}" -n freeipa 

    #Generate ca.crt and ca.key used by ipa server.
    temp_dir=$(mktemp -d)
    openssl genpkey -algorithm RSA -out "$temp_dir"/ca.key -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:3
    openssl req -x509 -sha256 -key "$temp_dir"/ca.key -nodes -new -days 365 -out "$temp_dir"/ca.crt -subj '/CN=freeipa-test/O=FREEIPA-TEST' -set_serial 1

    oc create secret tls freeipa-certs --cert="$temp_dir"/ca.crt --key="$temp_dir"/ca.key -n freeipa

    #Create a ConfigMap inside the openshift-config namespace to be used by the identity provider.
    oc create configmap ipa-ca --from-file=ca.crt="$temp_dir"/ca.crt -n openshift-config

    # Create a temporary file with a .yaml extension
    temp_file=$(mktemp /tmp/freeipa_manifest.XXXXXX.yaml)
    # Add the manifest to the temporary file
    cat <<'EOF' > "$temp_file"
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: freeipa
  name: freeipa
  namespace: freeipa
spec:
  replicas: 2
  selector:
    matchLabels:
      app: freeipa
  template:
    metadata:
      labels:
        app: freeipa
    spec:
      hostname: freeipa
      subdomain: freeipa
      initContainers:
      - name: step-1-gen-ipa-ca-csr
        image: quay.io/freeipa/freeipa-server:fedora-40
        securityContext:
          runAsUser: 0
        tty: true
        env:
        - name: DEBUG_TRACE
          value: ""
        - name: IPA_SERVER_INSTALL_OPTS
          value: "--unattended --external-ca --realm=IPA.EXAMPLE.COM  --domain=ipa.example.com --no-host-dns"
        - name: KUBERNETES
          value: "1"
        - name: PASSWORD
          valueFrom:
            secretKeyRef:
              name: freeipa
              key: PASSWORD
        - name: SYSTEMD_OFFLINE
          value: "1"
        - name: SYSTEMD_NSPAWN_API_VFS_WRITABLE
          value: "network"
        volumeMounts:
          - name: data
            mountPath: /data
          - name: systemd-tmp
            mountPath: /tmp
          - name: systemd-var-run
            mountPath: /var/run
          - name: systemd-var-dirsrv
            mountPath: /var/run/dirsrv
      - name: setup-certs
        image: quay.io/freeipa/freeipa-server:fedora-40
        securityContext:
          runAsUser: 0
        command: ["/bin/bash", "-c"]
        args:
          - |
            set -e
            set -x
            DATA="/data"
            NSSDB=/tmp/nssdb-$RANDOM
            PASSWORD_FILE=/tmp/nssdb-$RANDOM
            echo $RANDOM > $PASSWORD_FILE
            openssl pkcs12 -export -in /certs/tls.crt -inkey /certs/tls.key -out "$DATA"/ca.p12 -name "External CA" -passout file:$PASSWORD_FILE
            pki -d $NSSDB -C $PASSWORD_FILE client-init
            pki -d $NSSDB pkcs12-cert-mod --pkcs12-file "$DATA"/ca.p12 "External CA" --pkcs12-password-file $PASSWORD_FILE --trust-flags "CTu,Cu,Cu"
            pk12util -i "$DATA"/ca.p12 -d sql:$NSSDB -w $PASSWORD_FILE -k $PASSWORD_FILE
            echo -e "$RANDOM\n\n" | certutil -C -m 2346 -i "$DATA"/ipa.csr -o "$DATA"/ipa.crt -c 'External CA' -d $NSSDB -a --extSKID -f $PASSWORD_FILE
        volumeMounts:
          - name: data
            mountPath: /data
          - name: certs
            mountPath: /certs
      containers:
      - name: step-2-run-ipa-server
        image: quay.io/freeipa/freeipa-server:fedora-40
        securityContext:
          runAsUser: 0
        tty: true
        env:
        - name: DEBUG_TRACE
          value: ""
        - name: IPA_SERVER_INSTALL_OPTS
          value: "--unattended --external-cert-file=/data/ipa.crt --external-cert-file=/certs/tls.crt --realm=IPA.EXAMPLE.COM  --domain=ipa.example.com --no-host-dns"
        - name: KUBERNETES
          value: "1"
        - name: PASSWORD
          valueFrom:
            secretKeyRef:
              name: freeipa
              key: PASSWORD
        - name: SYSTEMD_OFFLINE
          value: "1"
        - name: SYSTEMD_NSPAWN_API_VFS_WRITABLE
          value: "network"
        ports:
          - name: ldap-tcp
            protocol: TCP
            containerPort: 389
          - name: ldaps-tcp
            protocol: TCP
            containerPort: 636
        volumeMounts:
          - name: freeipa-users
            mountPath: /users
          - name: certs
            mountPath: /certs
          - name: data
            mountPath: /data
          - name: systemd-tmp
            mountPath: /tmp
          - name: systemd-var-run
            mountPath: /var/run
          - name: systemd-var-dirsrv
            mountPath: /var/run/dirsrv
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/sh
              - -c
              - |
                # Redirect all output to stdout/stderr for logging
                exec > /proc/1/fd/1 2>/proc/1/fd/2
                # Wait Until FreeIPA service is ready
                until grep -q "FreeIPA server configured" /data/var/log/ipa-server-configure-first.log; do sleep 30; done
                echo "Adding freeipa users $username"
                echo "$PASSWORD" | kinit admin
                while IFS="," read -r username password; do echo "$password" | ipa user-add "$username" --first="$username" --last="User" --password-expiration="$(date -u -d "+1 week" +"%Y%m%d%H%M%SZ")" --password; done < /users/users.txt
      setHostnameAsFQDN: true
      volumes:
        - name: data
          emptyDir: {}
        - name: systemd-var-run
          emptyDir:
            medium: "Memory"
        - name: systemd-var-dirsrv
          emptyDir:
            medium: "Memory"
        - name: systemd-run-rpcbind
          emptyDir:
            medium: "Memory"
        - name: systemd-tmp
          emptyDir:
            medium: "Memory"
        - name: freeipa-users
          secret:
            secretName: freeipa-users-secret
        - name: certs
          secret:
            secretName: freeipa-certs
---
apiVersion: v1
kind: Service
metadata:
  name: freeipa
  labels:
    app: freeipa
  namespace: freeipa
spec:
  selector:
    app: freeipa
  ports:
    - name: ldap
      port: 389
      protocol: TCP
    - name: ldaps
      port: 636
      protocol: TCP
EOF

    oc apply -f "$temp_file"

    echo "Waiting for FreeIPA pod to be running and ready..."
    count=0
    max_attempts=20
    while :; do
        pod_status=$(oc get pods -n freeipa)
        echo "$pod_status" # print for when debugging is needed
        pod_status=$(echo "$pod_status" | grep freeipa)
        if [[ $pod_status == *"1/1"*"Running"* ]]; then
            echo "FreeIPA pod is running and ready."
            break
        fi

        sleep 30
        ((count++))

        if [[ $count -ge $max_attempts ]]; then
            echo "Timeout waiting for FreeIPA pod to be running and ready. Exiting."
            return 1
        fi
    done
}

# Function to configure the identity provider in OpenShift
function configure_identity_provider() {
    echo "Configuring OpenShift identity provider with FreeIPA"

    # current generation
    gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

    # Prepare the new FreeIPA identity provider configuration as a JSON object
    new_ipa_idp='{
        "ldap": {
            "attributes": {
                "email": ["mail"],
                "id": ["dn"],
                "name": ["cn"],
                "preferredUsername": ["uid"]
            },
            "ca": {
                "name": "ipa-ca"
            },
            "insecure": false,
            "url": "ldaps://freeipa.freeipa.freeipa.svc.cluster.local/cn=users,cn=accounts,dc=ipa,dc=example,dc=com?uid"
        },
        "mappingMethod": "claim",
        "name": "IPA",
        "type": "LDAP"
    }'

#"url": "ldaps://freeipa.freeipa.freeipa.svc.cluster.local/cn=users,cn=accounts,dc=ipa,dc=example,dc=com?uid"
# The FreeIPA pod uses the hostname "<pod hostname>.<svc_name>.<project_name>.svc.cluster.local" with a custom external CA certificate.
# To avoid certificate errors, we use the FreeIPA IDP URL format: <pod hostname>.<svc_name>.<project_name>.svc.cluster.local, which matches the FreeIPA pod hostname.

    # Since no IDP is configured, create a new array with the IPA IDP
    combined_idp_config="[$new_ipa_idp]"

    # Construct the JSON patch using a here-document
    json_patch=$(cat <<EOF
{
  "spec": {
    "identityProviders": $combined_idp_config
  }
}
EOF
)

    # Apply the patch
    if ! oc patch oauth cluster --type=merge -p "$json_patch"; then
        echo "Failed to apply the patch to configure FreeIPA IDP"
        exit 1
    fi

    # wait for oauth-openshift to rollout
    wait_auth=true
    expected_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.spec.replicas}')
    while $wait_auth;
    do
        available_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.availableReplicas}')
        new_gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
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
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]] || [[ "$CLUSTER_TYPE" == "hypershift-guest" ]]; then
        echo "Skip the step. The managed clusters generate the testing accounts by themselves"
        exit 0
    fi
fi

# Main script execution with error handling
set_proxy || handle_error "set_proxy"
set_kubeconfig || handle_error "set_kubeconfig"
check_idp || handle_error "check_idp"
set_users || handle_error "set_users"
configure_freeipa || handle_error "configure_freeipa"
configure_identity_provider || handle_error "configure_identity_provider"

# Installed FreeIPA Version
echo "FreeIPA pod is running and ready."
FREEIPA_POD=$(oc get pods -n freeipa -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
FREEIPA_VERSION=$(oc exec "$FREEIPA_POD" -c step-2-run-ipa-server -n freeipa -- ipa --version)
echo "FreeIPA Version: $FREEIPA_VERSION"

# Cleanup temporary files
echo "Cleaning up temporary files"
rm -Rivf "$temp_users" "$temp_dir" "$temp_file"
