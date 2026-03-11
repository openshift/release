#!/bin/bash

set -e
set -u
set -o pipefail

function check_if_hypershift_env () {
    if [ -f "${SHARED_DIR}/nested_kubeconfig" ]; then
        echo "this is a hypeshift Env"
        IS_HYPERSHIFT_ENV="yes"
    else
        # We must set IS_HYPERSHIFT_ENV="no" otherwise OCP CI will fail because this script sets "set -u".
        IS_HYPERSHIFT_ENV="no"
        return 0
    fi
    MC_KUBECONFIG_FILE="${SHARED_DIR}/hs-mc.kubeconfig"
    if [ -f "${MC_KUBECONFIG_FILE}" ]; then
        export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
    elif [ -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
        export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
    else
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    HYPERSHIFT_NAMESPACE=$(oc get hostedclusters -A -ojsonpath="{.items[?(@.metadata.name==\"$(cat ${SHARED_DIR}/cluster-name)\")].metadata.namespace}") || true
    if [ -z "${HYPERSHIFT_NAMESPACE}" ]; then
        echo -n "Failed to run 'oc get hostedclusters -A' likely due to no permission or other errors. "
        # It is observed in some CI jobs the user has the permission to run `oc get hostedcluster -n <NS>` but has no permission to run the wider `oc get hostedclusters -A`
        if [ -f "${SHARED_DIR}/hypershift-clusters-namespace" ]; then
            echo "The hypershift-clusters-namespace file exists. Using it"
            HYPERSHIFT_NAMESPACE=$(< "${SHARED_DIR}/hypershift-clusters-namespace")
        else
            echo "The hypershift-clusters-namespace file is not found. Falling back to the default"
            HYPERSHIFT_NAMESPACE=clusters
        fi
    fi
    count=$(oc get hostedclusters --no-headers --ignore-not-found -n "$HYPERSHIFT_NAMESPACE" | wc -l)
    echo "hostedcluster count: $count"
    if [ "$count" -lt 1 ]  ; then
        echo "namespace clusters don't have hostedcluster"
        exit 1
    fi
    # There are multiple hostedclusters when some jobs use one management cluster that is a CI-shared cluster
    cluster_name=$(cat ${SHARED_DIR}/cluster-name)
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
    # Don't quote the $TARGET_RESOURCE variable because it may include spaces
    current_idp_config=$(oc get $TARGET_RESOURCE -o jsonpath='{range '$IDP_FIELD'[*]}{.name}{" "}{.type}{"\n"}{end}')
    if [ -n "$current_idp_config" ] && [ "$current_idp_config" != "null" ] && [ -n "$USERS" ]; then
        echo -e "Skipping addition of new htpasswd IDP because already configured IDP as below:\n$current_idp_config"
        exit 0
    fi
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function set_users () {
    echo "set idp htpasswd users"
    # prepare users
    users=""
    htpass_file=/tmp/users.htpasswd

    for i in $(seq 1 50);
    do
        username="testuser-${i}"
        password=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
        users+="${username}:${password},"
        if [ -f "${htpass_file}" ]; then
            htpasswd -B -b ${htpass_file} "${username}" "${password}"
        else
            htpasswd -c -B -b ${htpass_file} "${username}" "${password}"
        fi
    done

    # current generation
    gen=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.metadata.generation}') || true
    if [ -z "$gen" ]; then
        # It is observed in some hypershift CI jobs the user has no permission to check into the OAUTH_NAMESPACE
        echo "Failed to run 'oc get deployment oauth-openshift' in the hosted cluster control plane namespace likely due to no permission. Will just add the IDP but skip checking the pods renew"
    fi

    # add users to cluster
    HTPASSWD_SECRET_NAME=${cluster_name:+hc-${cluster_name}-}htpasswd-idp-secret
    # Some jobs use one management cluster that is a CI-shared cluster. So do not use a hard code secret name
    oc create secret generic "${HTPASSWD_SECRET_NAME}" --from-file=htpasswd=${htpass_file} -n "$MIDDLE_NAMESPACE"
    echo "${HTPASSWD_SECRET_NAME}" > "${SHARED_DIR}/htpasswd-secret-name" # To be cleaned up if the job is a hypershift CI job
    oauth_file_src=/tmp/cucushift-oauth-src.yaml
    oauth_file_dst=/tmp/cucushift-oauth-dst.yaml
    # Don't quote the $TARGET_RESOURCE variable because it may include spaces
    oc get $TARGET_RESOURCE -o json > "${oauth_file_src}"
    jq $IDP_FIELD' += [{"htpasswd":{"fileData":{"name":"'${HTPASSWD_SECRET_NAME}'"}},"challenge":"true","login":"true","mappingMethod":"claim","name":"cucushift-htpasswd-provider","type":"HTPasswd"}]' "${oauth_file_src}" > "${oauth_file_dst}"
    oc replace -f "${oauth_file_dst}"

    if [ -z "$gen" ]; then
        echo "Due to unable to check the pods renew, just wait a while"
        sleep 5m
    else
        echo "Wait up to 10 minutes for htpasswd ready"
        auth_ready=false
        count=0
        expected_replicas=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.spec.replicas}')
        while [[ $count -lt 40 ]]
        do
            available_replicas=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.status.availableReplicas}')
            new_gen=$(oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.metadata.generation}')
            if [[ $expected_replicas == "$available_replicas" && $((new_gen)) -gt $((gen)) ]]; then
                auth_ready=true
                break
            else
                echo "waiting 15s now. elapsed: $(( 15 * $count )) seconds"
                sleep 15s
                count=$(( count + 1 ))
            fi
        done

        if [[ $auth_ready == "false" ]];then
            echo "Error: the idp-htpasswd is not ready in given time"
            echo "oc get deployment oauth-openshift -n $OAUTH_NAMESPACE -o jsonpath={.status}"
            oc get deployment oauth-openshift -n "$OAUTH_NAMESPACE" -o jsonpath='{.status}'
            echo "oc get pods -n $OAUTH_NAMESPACE"
            oc get pods -n "$OAUTH_NAMESPACE"
            exit 1
        fi
    fi

    # store users in a shared file
    if [ -f "${SHARED_DIR}/runtime_env" ] ; then
        source "${SHARED_DIR}/runtime_env"
    fi
    runtime_env="${SHARED_DIR}/runtime_env"
    users=${users::-1}


    cat <<EOF >>"${runtime_env}"
export USERS=${users}
EOF
}

if [ -f "${SHARED_DIR}/cluster-type" ] ; then
    CLUSTER_TYPE=$(cat "${SHARED_DIR}/cluster-type")
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]]; then
        echo "Skip the step. The managed clusters generate the testing accounts by themselves"
        exit 0
    fi
fi

set_proxy
check_if_hypershift_env
set_common_variables
check_idp
set_users
