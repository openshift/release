#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Waits up to 5 minutes for InstallPlan to be created
wait_for_installplan () {
    echo "[$(date --utc +%FT%T.%3NZ)] Waiting for installPlan to be created"
    # store subscription name and install namespace to shared directory for upgrade step
    echo "${OO_INSTALL_NAMESPACE}" > "${SHARED_DIR}"/oo-install-namespace
    echo "${SUB}" > "${SHARED_DIR}"/oo-subscription

    FOUND_INSTALLPLAN=false
    # wait up to 5 minutes for CSV installPlan to appear
    for _ in $(seq 1 60); do
        INSTALL_PLAN=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installplan.name}' || true)

        if [[ -n "$INSTALL_PLAN" ]]; then
            oc -n "$OO_INSTALL_NAMESPACE" patch installPlan "${INSTALL_PLAN}" --type merge --patch '{"spec":{"approved":true}}'
            FOUND_INSTALLPLAN=true
            break
        fi
        sleep 5
    done
}

# Waits up to 10 minutes for CSV to become ready
wait_for_csv () {
    for _ in $(seq 1 60); do
        CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
        if [[ -n "$CSV" ]]; then
            if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
                echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion \"$CSV\" ready"

                DEPLOYMENT_ART="oo_deployment_details.yaml"
                echo "[$(date --utc +%FT%T.%3NZ)] Saving deployment details in ${DEPLOYMENT_ART} as a shared artifact"
                cat > "${ARTIFACT_DIR}/${DEPLOYMENT_ART}" <<EOF
---
csv: "${CSV}"
operatorgroup: "${OPERATORGROUP}"
subscription: "${SUB}"
catalogsource: "${CATSRC}"
install_namespace: "${OO_INSTALL_NAMESPACE}"
target_namespaces: "${OO_TARGET_NAMESPACES}"
deployment_start_time: "${DEPLOYMENT_START_TIME}"
EOF
                cp "${ARTIFACT_DIR}/${DEPLOYMENT_ART}" "${SHARED_DIR}/${DEPLOYMENT_ART}"
                echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
                exit 0
            fi
        fi
        sleep 10
    done
    echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for csv to become ready"
}

# Waits up to 10 minutes until the Catalog source state is 'READY'
wait_for_catalogsource () {
    for i in $(seq 1 120); do
        CATSRC_STATE=$(oc get catalogsources/"$CATSRC" -n "$CS_NAMESPACE" -o jsonpath='{.status.connectionState.lastObservedState}')
        echo $CATSRC_STATE
        if [ "$CATSRC_STATE" = "READY" ] ; then
            echo "[$(date --utc +%FT%T.%3NZ)] Catalogsource created successfully after waiting $((5*i)) seconds"
            echo "[$(date --utc +%FT%T.%3NZ)] current state of catalogsource is \"$CATSRC_STATE\""
            IS_CATSRC_CREATED=true
            break
        fi
        sleep 5
    done
}

# Creates CatalogSource
create_catalogsource () {
    CATSRC=""
    IS_CATSRC_CREATED=${IS_CATSRC_CREATED:-false}
    if [ "$IS_CATSRC_CREATED" = false ] ; then
        CS_MANIFEST=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  $CS_NAMESTANZA
  namespace: $CS_NAMESPACE
spec:
  sourceType: grpc
  image: "$OO_INDEX"
$CS_PODCONFIG
EOF
)

        echo "[$(date --utc +%FT%T.%3NZ)] Creating CatalogSource: $CS_MANIFEST"
        CATSRC=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${CS_MANIFEST}" )
        echo "[$(date --utc +%FT%T.%3NZ)] CatalogSource name is \"$CATSRC\""

    else
        echo "$CS_NAMESTANZA"
        arrIN=("${CS_NAMESTANZA//:/ }")
        CATSRC=${arrIN[1]}
        CATSRC=`echo $CATSRC | sed 's/ *$//g'`
    fi
}

# Retries Subscription creation
# Deletes current Subscription in the namespace before retrying creating a new one
retry_subscription_creation () {
    echo "[$(date --utc +%FT%T.%3NZ)] Deleting subscription $SUB in the namespace $OO_INSTALL_NAMESPACE"
    oc delete subscription $SUB -n $OO_INSTALL_NAMESPACE

    echo "[$(date --utc +%FT%T.%3NZ)] Creating subscription"
    SUB=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${SUB_MANIFEST}" )
    echo "[$(date --utc +%FT%T.%3NZ)] Subscription name is \"$SUB\""
}

# Re-tries InstallPlan creation which includes deleting Subscription, creating it again, and waiting for InstallPlan to come up
retry_installplan_creation () {
    retry_attempts=2

    while [[ "$FOUND_INSTALLPLAN" = false && "$retry_attempts" -ne 0 ]]; do
        echo "[$(date --utc +%FT%T.%3NZ)] Failed to find installPlan for subscription"
        echo "[$(date --utc +%FT%T.%3NZ)] Retrying subscription creation...${retry_attempts} attempts left"

        retry_subscription_creation
        wait_for_installplan

        retry_attempts=$((retry_attempts-1))
    done
}

# Enables hybrid overlay feature on a running cluster
enable_hybrid_overlay () {
    VXLAN_PORT=4789
    
    oc patch Network.operator.openshift.io cluster --type='merge' --patch '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"hybridOverlayConfig":{"hybridOverlayVXLANPort":'"${VXLAN_PORT}"',"hybridClusterNetwork":[{"cidr": "10.132.0.0/14","hostPrefix": 23}]}}}}}'
    
    # wait for the ovnKubernetesConfig to update
    start_time=$(date +%s)
    while [ -z "$(oc get network.operator.openshift.io -o jsonpath="{.items[0].spec.defaultNetwork.ovnKubernetesConfig.hybridOverlayConfig}")" ]; do
        if [ $(($(date +%s) - $start_time)) -gt 300 ]; then
            echo "Timeout waiting for the ovnKubernetesConfig to update"
            echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
            exit 1
        fi
    done
}

# Enable hybrid overlay
if [[ "${ENABLE_HYBRID_OVERLAY}" == "true" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Enabling hybrid overlay feature on a running cluster"
    enable_hybrid_overlay
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# In upgrade tests, the subscribe step installs the initial version of the operator, so
# it needs to install from the INITIAL_CHANNEL
if [ -n "${INITIAL_CHANNEL}" ]; then
    OO_CHANNEL="${INITIAL_CHANNEL}"
fi

if [[ $JOB_NAME != rehearse-* ]]; then
    if [[ -z ${OO_INDEX:-} ]] || [[ -z ${OO_PACKAGE:-} ]] || [[ -z ${OO_CHANNEL:-} ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] At least of required variables OO_INDEX=${OO_INDEX:-} OO_PACKAGE=${OO_PACKAGE:-} OO_CHANNEL=${OO_CHANNEL:-} is unset"
        echo "[$(date --utc +%FT%T.%3NZ)] Variables are only allowed to be unset in rehearsals"
        echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
        exit 1
    fi
fi

echo "[$(date --utc +%FT%T.%3NZ)] == Parameters:"
echo "[$(date --utc +%FT%T.%3NZ)] OO_INDEX:             $OO_INDEX"
echo "[$(date --utc +%FT%T.%3NZ)] OO_PACKAGE:           $OO_PACKAGE"
echo "[$(date --utc +%FT%T.%3NZ)] OO_CHANNEL:           $OO_CHANNEL"
echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE: $OO_INSTALL_NAMESPACE"
echo "[$(date --utc +%FT%T.%3NZ)] OO_TARGET_NAMESPACES: $OO_TARGET_NAMESPACES"
echo "[$(date --utc +%FT%T.%3NZ)] OO_CONFIG_ENVVARS:    $OO_CONFIG_ENVVARS"
echo "[$(date --utc +%FT%T.%3NZ)] TEST_MODE:            $TEST_MODE"
echo "[$(date --utc +%FT%T.%3NZ)] EVAL_CONFIG_ENVVARS:  $EVAL_CONFIG_ENVVARS"
echo "[$(date --utc +%FT%T.%3NZ)] ENABLE_HYBRID_OVERLAY:$ENABLE_HYBRID_OVERLAY"

if [[ -f "${SHARED_DIR}/operator-install-namespace.txt" ]]; then
    OO_INSTALL_NAMESPACE=$(cat "$SHARED_DIR"/operator-install-namespace.txt)
elif [[ "$OO_INSTALL_NAMESPACE" == "!create" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $OO_INSTALL_NAMESPACE"
else
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
fi

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
    OO_INSTALL_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
    )
fi

if [[ "${OO_INSTALL_NAMESPACE}" =~ ^openshift- ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Setting label security.openshift.io/scc.podSecurityLabelSync value to true on the namespace \"$OO_INSTALL_NAMESPACE\""
    oc label --overwrite ns "${OO_INSTALL_NAMESPACE}" security.openshift.io/scc.podSecurityLabelSync=true
fi

echo "Installing \"$OO_PACKAGE\" in namespace \"$OO_INSTALL_NAMESPACE\""

if [[ "$OO_TARGET_NAMESPACES" == "!install" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_TARGET_NAMESPACES is '!install': targeting operator installation namespace ($OO_INSTALL_NAMESPACE)"
    OO_TARGET_NAMESPACES="$OO_INSTALL_NAMESPACE"
elif [[ "$OO_TARGET_NAMESPACES" == "!all" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_TARGET_NAMESPACES is '!all': all namespaces will be targeted"
    OO_TARGET_NAMESPACES=""
fi

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)

if [[ $(echo "$OPERATORGROUP" | wc -w) -gt 1 ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Error: multiple OperatorGroups in namespace \"$OO_INSTALL_NAMESPACE\": $OPERATORGROUP" 1>&2
    oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o yaml >"$ARTIFACT_DIR/operatorgroups-$OO_INSTALL_NAMESPACE.yaml"
    echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
    exit 1
elif [[ -n "$OPERATORGROUP" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup "$OPERATORGROUP" -o yaml >"$ARTIFACT_DIR/og-$OPERATORGROUP-orig.yaml"
    OG_OPERATION=apply
    OG_NAMESTANZA="name: $OPERATORGROUP"
else
    echo "[$(date --utc +%FT%T.%3NZ)] OperatorGroup does not exist: creating it"
    OG_OPERATION=create
    if [[ "${TEST_MODE}" == "msp" ]]; then
      OG_NAMESTANZA="name: redhat-layered-product-og"
    elif [[ "${TEST_MODE}" == "qe-ci" ]]; then
      OG_NAMESTANZA="generateName: qe-ci-"
    else
      OG_NAMESTANZA="generateName: oo-"
    fi
fi

OPERATORGROUP=$(
    oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_TARGET_NAMESPACES]
EOF
)

echo "[$(date --utc +%FT%T.%3NZ)] OperatorGroup name is \"$OPERATORGROUP\""
echo "[$(date --utc +%FT%T.%3NZ)] Creating CatalogSource"

if [[ "${TEST_MODE}" == "msp" ]]; then
  CS_NAMESTANZA="name: addon-$OO_PACKAGE-catalog"
  CS_NAMESPACE="openshift-marketplace"
elif [[ "${TEST_MODE}" == "qe-ci" ]]; then
  CS_NAMESTANZA="name: qe-app-registry"
  CS_NAMESPACE="openshift-marketplace"
else
  CS_NAMESTANZA="generateName: oo-"
  CS_NAMESPACE="${OO_INSTALL_NAMESPACE}"
fi

# The securityContextConfig API field was added in 4.12, but the default "enforce" is "restricted" since OCP 4.14
# But once "featureSet: TechPreviewNoUpgrade" enabeld, the PSA enforce will be changed to "restricted" from "privileged" since OCP 4.12.
# $ oc get featuregate cluster -o yaml
# apiVersion: config.openshift.io/v1
# kind: FeatureGate
# metadata:
#   name: cluster
# spec:
#   featureSet: TechPreviewNoUpgrade
# So, add "securityContextConfig: restricted" since OCP 4.12
CS_PODCONFIG=""
OCP_MINOR_VERSION=$(oc version | grep "Server Version" | cut -d '.' -f2)
if [ "$OCP_MINOR_VERSION" -gt "11" ]; then
  CS_PODCONFIG=$(cat <<EOF
  grpcPodConfig:
    securityContextConfig: restricted
EOF
)
fi

# qe-ci test mode using enable-qe-catalogsource create the catalogsource then no need to create extra catalogsource again
if [[ "${TEST_MODE}" == "qe-ci" ]]; then
  IS_CATSRC_CREATED=true
  echo "[$(date --utc +%FT%T.%3NZ)] TEST_MODE is qe-ci, using the exist qe-app-registry catalog install the optional operator, skipped create catalogSource"  
else
  create_catalogsource
  wait_for_catalogsource
fi

retry_attempts_catalogsource=2
while [[ "$IS_CATSRC_CREATED" = false && "$retry_attempts_catalogsource" -ne 0 ]]; do
    echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for the catalog source $CATSRC to become ready after 10 minutes."

    echo "[$(date --utc +%FT%T.%3NZ)] Retrying catalogsource creation...${retry_attempts_catalogsource} attempts left"
    echo "[$(date --utc +%FT%T.%3NZ)] Deleting catalogsource $CATSRC in the namespace $CS_NAMESPACE"
    oc delete catalogsource $CATSRC -n $CS_NAMESPACE
    
    create_catalogsource
    wait_for_catalogsource

    retry_attempts_catalogsource=$((retry_attempts_catalogsource-1))
done

if [ $IS_CATSRC_CREATED = false ] ; then
    echo "[$(date --utc +%FT%T.%3NZ)] Timed out waiting for the catalog source $CATSRC to become ready after 10 minutes."
    echo "[$(date --utc +%FT%T.%3NZ)] Catalogsource state at timeout is \"$CATSRC_STATE\""
    echo "[$(date --utc +%FT%T.%3NZ)] Catalogsource image used is \"$OO_INDEX\""
    echo "[$(date --utc +%FT%T.%3NZ)] All retry attempts failed"
    echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
    exit 1
fi

# A suggestion was made in OCPBUGS-6523 for CVP to add 5-10s wait time after CatalogSource reports READY and before creating the Subscription
sleep 10

DEPLOYMENT_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "[$(date --utc +%FT%T.%3NZ)] Set the deployment start time: ${DEPLOYMENT_START_TIME}"
echo "[$(date --utc +%FT%T.%3NZ)] Creating Subscription"

if [[ "${TEST_MODE}" == "msp" ]]; then
  SUB_NAMESTANZA="name: addon-$OO_PACKAGE"
elif [[ "${TEST_MODE}" == "qe-ci" ]]; then
  SUB_NAMESTANZA="generateName: qe-ci-"
  CATSRC="qe-app-registry"
  CS_NAMESPACE="openshift-marketplace"
else
  SUB_NAMESTANZA="generateName: oo-"
fi

CONFIG_ENVVARS=""
if [ -n "${OO_CONFIG_ENVVARS}" ]; then
    envvar_yaml=""
    IFS=',' read -ra vars <<< "${OO_CONFIG_ENVVARS}"
    for var in "${vars[@]}"; do
        IFS='=' read -ra kv <<< "$var"
        if [ ${#kv[@]} -eq 2 ]; then
            val=${kv[1]}
            [ -n "${EVAL_CONFIG_ENVVARS}" ] && val=$(eval echo "${kv[1]}")
            [ -n "${envvar_yaml}" ] && envvar_yaml+=$'\n'
            envvar_yaml+="      - name: ${kv[0]}"$'\n'"        value: ${val}"
        fi
    done
    if [ -n "${envvar_yaml}" ]; then
        CONFIG_ENVVARS="  config:"$'\n'"    env:"$'\n'"${envvar_yaml}"
    fi
fi

SUB_MANIFEST=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  $SUB_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  name: $OO_PACKAGE
  channel: "$OO_CHANNEL"
  source: $CATSRC
  sourceNamespace: $CS_NAMESPACE
  installPlanApproval: Manual
EOF
)

# Add startingCSV if one is provided
if [ -n "${INITIAL_CSV}" ]; then
    SUB_MANIFEST="${SUB_MANIFEST}"$'\n'"  startingCSV: ${INITIAL_CSV}"
fi

# Add config.env if any environment variable is provided
if [ -n "${CONFIG_ENVVARS}" ]; then
    SUB_MANIFEST="${SUB_MANIFEST}"$'\n'"${CONFIG_ENVVARS}"
fi

echo "[$(date --utc +%FT%T.%3NZ)] SUB_MANIFEST : ${SUB_MANIFEST} "

SUB=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${SUB_MANIFEST}" )

echo "[$(date --utc +%FT%T.%3NZ)] Subscription name is \"$SUB\""

wait_for_installplan

if [ "$FOUND_INSTALLPLAN" = false ] ; then
    retry_installplan_creation
fi

if [ "$FOUND_INSTALLPLAN" = true ] ; then
    echo "[$(date --utc +%FT%T.%3NZ)] Install Plan approved"
    echo "[$(date --utc +%FT%T.%3NZ)] Waiting for ClusterServiceVersion to become ready..."
    wait_for_csv
    retry_attempts_csv=2
    while [[ "$retry_attempts_csv" -ne 0 ]]; do
        echo "[$(date --utc +%FT%T.%3NZ)] Retrying CSV creation...${retry_attempts_csv} attempts left"

        # Delete CSV if it exists
        if [[ -n "${CSV:-}" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] CSV \"${CSV}\" was created but never became ready. Deleting CSV \"${CSV}\"..."
            oc delete csv $CSV -n $OO_INSTALL_NAMESPACE
        else
            echo "[$(date --utc +%FT%T.%3NZ)] There is no CSV in the namespace \"${OO_INSTALL_NAMESPACE}\""
        fi

        echo "Re-creating Subscription and InstallPlan"
        retry_subscription_creation
        wait_for_installplan

        if [ "$FOUND_INSTALLPLAN" = false ]; then
            retry_installplan_creation
        fi
        
        if [ "$FOUND_INSTALLPLAN" = true ]; then
            echo "[$(date --utc +%FT%T.%3NZ)] Install Plan approved"
            echo "[$(date --utc +%FT%T.%3NZ)] Waiting for ClusterServiceVersion to become ready..."
            wait_for_csv
        else
            echo "[$(date --utc +%FT%T.%3NZ)] Failed to find installPlan for subscription"
        fi

        retry_attempts_csv=$((retry_attempts_csv-1))
    done
    echo "[$(date --utc +%FT%T.%3NZ)] All retry attempts failed"
else
    echo "[$(date --utc +%FT%T.%3NZ)] Failed to find installPlan for subscription"
    echo "[$(date --utc +%FT%T.%3NZ)] All retry attempts failed"
fi

NS_ART="$ARTIFACT_DIR/ns-$OO_INSTALL_NAMESPACE.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping Namespace $OO_INSTALL_NAMESPACE as $NS_ART"
oc get namespace "$OO_INSTALL_NAMESPACE" -o yaml >"$NS_ART"

OG_ART="$ARTIFACT_DIR/og-$OPERATORGROUP.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping OperatorGroup $OPERATORGROUP as $OG_ART"
oc get -n "$OO_INSTALL_NAMESPACE" operatorgroup "$OPERATORGROUP" -o yaml >"$OG_ART"

CS_ART="$ARTIFACT_DIR/cs-$CATSRC.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping CatalogSource $CATSRC as $CS_ART"
oc get -n "$CS_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$CS_ART"
for field in message reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" catalogsource "$CATSRC" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] CatalogSource $CATSRC status $field: $VALUE"
    fi
done

SUB_ART="$ARTIFACT_DIR/sub-$SUB.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping Subscription $SUB as $SUB_ART"
oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$SUB_ART"
for field in state reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Subscription $SUB status $field: $VALUE"
    fi
done

if [[ -n "${CSV:-}" ]]; then
    CSV_ART="$ARTIFACT_DIR/csv-$CSV.yaml"
    echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion $CSV was created but never became ready"
    echo "[$(date --utc +%FT%T.%3NZ)] Dumping ClusterServiceVersion $CSV as $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o yaml >"$CSV_ART"
    for field in phase message reason; do
        VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o jsonpath="{.status.$field}" || true)"
        if [[ -n "$VALUE" ]]; then
            echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion $CSV status $field: $VALUE"
        fi
    done
else
    CSV_ART="$ARTIFACT_DIR/$OO_INSTALL_NAMESPACE-all-csvs.yaml"
    echo "[$(date --utc +%FT%T.%3NZ)] ClusterServiceVersion was never created"
    echo "[$(date --utc +%FT%T.%3NZ)] Dumping all ClusterServiceVersions in namespace $OO_INSTALL_NAMESPACE to $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"
fi

INSTALLPLANS_ART="$ARTIFACT_DIR/installPlans.yaml"
echo "[$(date --utc +%FT%T.%3NZ)] Dumping all installPlans in namespace $OO_INSTALL_NAMESPACE as $INSTALLPLANS_ART"
oc get -n "$OO_INSTALL_NAMESPACE" installplans -o yaml >"$INSTALLPLANS_ART"

echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution With Failures !"
exit 1
