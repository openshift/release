#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Waits up to 5 minutes for InstallPlan to be created
wait_for_installplan () {
    echo "Waiting for installPlan to be created"
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
                echo "ClusterServiceVersion \"$CSV\" ready"

                DEPLOYMENT_ART="oo_deployment_details.yaml"
                echo "Saving deployment details in ${DEPLOYMENT_ART} as a shared artifact"
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
                exit 0
            fi
        fi
        sleep 10
    done
    echo "Timed out waiting for csv to become ready"
}

# Waits up to 10 minutes until the Catalog source state is 'READY'
wait_for_catalogsource () {
    for i in $(seq 1 120); do
        CATSRC_STATE=$(oc get catalogsources/"$CATSRC" -n "$CS_NAMESPACE" -o jsonpath='{.status.connectionState.lastObservedState}')
        echo $CATSRC_STATE
        if [ "$CATSRC_STATE" = "READY" ] ; then
            echo "Catalogsource created successfully after waiting $((5*i)) seconds"
            echo "current state of catalogsource is \"$CATSRC_STATE\""
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

        echo "Creating CatalogSource: $CS_MANIFEST"
        CATSRC=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${CS_MANIFEST}" )
        echo "CatalogSource name is \"$CATSRC\""

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
    echo "Deleting subscription $SUB in the namespace $OO_INSTALL_NAMESPACE"
    oc delete subscription $SUB -n $OO_INSTALL_NAMESPACE

    echo "Creating subscription"
    SUB=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${SUB_MANIFEST}" )
    echo "Subscription name is \"$SUB\""
}

# Re-tries InstallPlan creation which includes deleting Subscription, creating it again, and waiting for InstallPlan to come up
retry_installplan_creation () {
    retry_attempts=2

    while [[ "$FOUND_INSTALLPLAN" = false && "$retry_attempts" -ne 0 ]]; do
        echo "Failed to find installPlan for subscription"
        echo "Retrying subscription creation...${retry_attempts} attempts left"

        retry_subscription_creation
        wait_for_installplan

        retry_attempts=$((retry_attempts-1))
    done
}

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
        echo "At least of required variables OO_INDEX=${OO_INDEX:-} OO_PACKAGE=${OO_PACKAGE:-} OO_CHANNEL=${OO_CHANNEL:-} is unset"
        echo "Variables are only allowed to be unset in rehearsals"
        exit 1
    fi
fi

echo "== Parameters:"
echo "OO_INDEX:             $OO_INDEX"
echo "OO_PACKAGE:           $OO_PACKAGE"
echo "OO_CHANNEL:           $OO_CHANNEL"
echo "OO_INSTALL_NAMESPACE: $OO_INSTALL_NAMESPACE"
echo "OO_TARGET_NAMESPACES: $OO_TARGET_NAMESPACES"
echo "TEST_MODE: $TEST_MODE"

if [[ -f "${SHARED_DIR}/operator-install-namespace.txt" ]]; then
    OO_INSTALL_NAMESPACE=$(cat "$SHARED_DIR"/operator-install-namespace.txt)
elif [[ "$OO_INSTALL_NAMESPACE" == "!create" ]]; then
    echo "OO_INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $OO_INSTALL_NAMESPACE"
else
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
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
    echo "Setting label security.openshift.io/scc.podSecurityLabelSync value to true on the namespace \"$OO_INSTALL_NAMESPACE\""
    oc label --overwrite ns "${OO_INSTALL_NAMESPACE}" security.openshift.io/scc.podSecurityLabelSync=true
fi

echo "Installing \"$OO_PACKAGE\" in namespace \"$OO_INSTALL_NAMESPACE\""

if [[ "$OO_TARGET_NAMESPACES" == "!install" ]]; then
    echo "OO_TARGET_NAMESPACES is '!install': targeting operator installation namespace ($OO_INSTALL_NAMESPACE)"
    OO_TARGET_NAMESPACES="$OO_INSTALL_NAMESPACE"
elif [[ "$OO_TARGET_NAMESPACES" == "!all" ]]; then
    echo "OO_TARGET_NAMESPACES is '!all': all namespaces will be targeted"
    OO_TARGET_NAMESPACES=""
fi

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)

if [[ $(echo "$OPERATORGROUP" | wc -w) -gt 1 ]]; then
    echo "Error: multiple OperatorGroups in namespace \"$OO_INSTALL_NAMESPACE\": $OPERATORGROUP" 1>&2
    oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o yaml >"$ARTIFACT_DIR/operatorgroups-$OO_INSTALL_NAMESPACE.yaml"
    exit 1
elif [[ -n "$OPERATORGROUP" ]]; then
    echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup "$OPERATORGROUP" -o yaml >"$ARTIFACT_DIR/og-$OPERATORGROUP-orig.yaml"
    OG_OPERATION=apply
    OG_NAMESTANZA="name: $OPERATORGROUP"
else
    echo "OperatorGroup does not exist: creating it"
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

echo "OperatorGroup name is \"$OPERATORGROUP\""
echo "Creating CatalogSource"

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
  echo "TEST_MODE is qe-ci, using the exist qe-app-registry catalog install the optional operator, skipped create catalogSource"  
else
  create_catalogsource
  wait_for_catalogsource
fi

retry_attempts_catalogsource=2
while [[ "$IS_CATSRC_CREATED" = false && "$retry_attempts_catalogsource" -ne 0 ]]; do
    echo "Timed out waiting for the catalog source $CATSRC to become ready after 10 minutes."

    echo "Retrying catalogsource creation...${retry_attempts_catalogsource} attempts left"
    echo "Deleting catalogsource $CATSRC in the namespace $CS_NAMESPACE"
    oc delete catalogsource $CATSRC -n $CS_NAMESPACE
    
    create_catalogsource
    wait_for_catalogsource

    retry_attempts_catalogsource=$((retry_attempts_catalogsource-1))
done

if [ $IS_CATSRC_CREATED = false ] ; then
    echo "Timed out waiting for the catalog source $CATSRC to become ready after 10 minutes."
    echo "Catalogsource state at timeout is \"$CATSRC_STATE\""
    echo "Catalogsource image used is \"$OO_INDEX\""
    echo "All retry attempts failed"
    exit 1
fi

# A suggestion was made in OCPBUGS-6523 for CVP to add 5-10s wait time after CatalogSource reports READY and before creating the Subscription
sleep 10

DEPLOYMENT_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "Set the deployment start time: ${DEPLOYMENT_START_TIME}"
echo "Creating Subscription"

if [[ "${TEST_MODE}" == "msp" ]]; then
  SUB_NAMESTANZA="name: addon-$OO_PACKAGE"
elif [[ "${TEST_MODE}" == "qe-ci" ]]; then
  SUB_NAMESTANZA="generateName: qe-ci-"
  CATSRC="qe-app-registry"
  CS_NAMESPACE="openshift-marketplace"
else
  SUB_NAMESTANZA="generateName: oo-"
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

# Add startingCSV is one is provided
if [ -n "${INITIAL_CSV}" ]; then
    SUB_MANIFEST="${SUB_MANIFEST}"$'\n'"  startingCSV: ${INITIAL_CSV}"
fi

echo "SUB_MANIFEST : ${SUB_MANIFEST} "

SUB=$(oc create -f - -o jsonpath='{.metadata.name}' <<< "${SUB_MANIFEST}" )

echo "Subscription name is \"$SUB\""

wait_for_installplan

if [ "$FOUND_INSTALLPLAN" = false ] ; then
    retry_installplan_creation
fi

if [ "$FOUND_INSTALLPLAN" = true ] ; then
    echo "Install Plan approved"
    echo "Waiting for ClusterServiceVersion to become ready..."
    wait_for_csv
    retry_attempts_csv=2
    while [[ "$retry_attempts_csv" -ne 0 ]]; do
        echo "Retrying CSV creation...${retry_attempts_csv} attempts left"

        # Delete CSV if it exists
        if [[ -n "${CSV:-}" ]]; then
            echo "CSV \"${CSV}\" was created but never became ready. Deleting CSV \"${CSV}\"..."
            oc delete csv $CSV -n $OO_INSTALL_NAMESPACE
        else
            echo "There is no CSV in the namespace \"${OO_INSTALL_NAMESPACE}\""
        fi

        echo "Re-creating Subscription and InstallPlan"
        retry_subscription_creation
        wait_for_installplan

        if [ "$FOUND_INSTALLPLAN" = false ]; then
            retry_installplan_creation
        fi
        
        if [ "$FOUND_INSTALLPLAN" = true ]; then
            echo "Install Plan approved"
            echo "Waiting for ClusterServiceVersion to become ready..."
            wait_for_csv
        else
            echo "Failed to find installPlan for subscription"
        fi

        retry_attempts_csv=$((retry_attempts_csv-1))
    done
    echo "All retry attempts failed"
else
    echo "Failed to find installPlan for subscription"
    echo "All retry attempts failed"
fi

NS_ART="$ARTIFACT_DIR/ns-$OO_INSTALL_NAMESPACE.yaml"
echo "Dumping Namespace $OO_INSTALL_NAMESPACE as $NS_ART"
oc get namespace "$OO_INSTALL_NAMESPACE" -o yaml >"$NS_ART"

OG_ART="$ARTIFACT_DIR/og-$OPERATORGROUP.yaml"
echo "Dumping OperatorGroup $OPERATORGROUP as $OG_ART"
oc get -n "$OO_INSTALL_NAMESPACE" operatorgroup "$OPERATORGROUP" -o yaml >"$OG_ART"

CS_ART="$ARTIFACT_DIR/cs-$CATSRC.yaml"
echo "Dumping CatalogSource $CATSRC as $CS_ART"
oc get -n "$CS_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$CS_ART"
for field in message reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" catalogsource "$CATSRC" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  CatalogSource $CATSRC status $field: $VALUE"
    fi
done

SUB_ART="$ARTIFACT_DIR/sub-$SUB.yaml"
echo "Dumping Subscription $SUB as $SUB_ART"
oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$SUB_ART"
for field in state reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  Subscription $SUB status $field: $VALUE"
    fi
done

if [[ -n "${CSV:-}" ]]; then
    CSV_ART="$ARTIFACT_DIR/csv-$CSV.yaml"
    echo "ClusterServiceVersion $CSV was created but never became ready"
    echo "Dumping ClusterServiceVersion $CSV as $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o yaml >"$CSV_ART"
    for field in phase message reason; do
        VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o jsonpath="{.status.$field}" || true)"
        if [[ -n "$VALUE" ]]; then
            echo "  ClusterServiceVersion $CSV status $field: $VALUE"
        fi
    done
else
    CSV_ART="$ARTIFACT_DIR/$OO_INSTALL_NAMESPACE-all-csvs.yaml"
    echo "ClusterServiceVersion was never created"
    echo "Dumping all ClusterServiceVersions in namespace $OO_INSTALL_NAMESPACE to $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"
fi

INSTALLPLANS_ART="$ARTIFACT_DIR/installPlans.yaml"
echo "Dumping all installPlans in namespace $OO_INSTALL_NAMESPACE as $INSTALLPLANS_ART"
oc get -n "$OO_INSTALL_NAMESPACE" installplans -o yaml >"$INSTALLPLANS_ART"

exit 1
