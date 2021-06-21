#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ $JOB_NAME != rehearse-* ]]; then
    if [[ -z ${INDEX_IMAGE:-} ]] || [[ -z ${PACKAGE:-} ]] || [[ -z ${CHANNEL:-} ]]; then
        echo "At least of required variables INDEX_IMAGE=${INDEX_IMAGE:-} PACKAGE=${PACKAGE:-} CHANNEL=${CHANNEL:-} is unset"
        echo "Variables are only allowed to be unset in rehearsals"
        exit 1
    fi
fi

echo "== Parameters:"
echo "INDEX_IMAGE:       $INDEX_IMAGE"
echo "PACKAGE:           $PACKAGE"
echo "CHANNEL:           $CHANNEL"
echo "INSTALL_NAMESPACE: $INSTALL_NAMESPACE"
echo "TARGET_NAMESPACES: $TARGET_NAMESPACES"

if [[ -f "${SHARED_DIR}/operator-install-namespace.txt" ]]; then
    INSTALL_NAMESPACE=$(cat "$SHARED_DIR"/operator-install-namespace.txt)
elif [[ "$INSTALL_NAMESPACE" == "!create" ]]; then
    echo "INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$INSTALL_NAMESPACE"; then
    echo "INSTALL_NAMESPACE is '$INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $INSTALL_NAMESPACE"
else
    echo "INSTALL_NAMESPACE is '$INSTALL_NAMESPACE'"
fi

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
    INSTALL_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
    )
fi

echo "Installing \"$PACKAGE\" in namespace \"$INSTALL_NAMESPACE\""

if [[ "$TARGET_NAMESPACES" == "!install" ]]; then
    echo "TARGET_NAMESPACES is '!install': targeting operator installation namespace ($INSTALL_NAMESPACE)"
    TARGET_NAMESPACES="$INSTALL_NAMESPACE"
elif [[ "$TARGET_NAMESPACES" == "!all" ]]; then
    echo "TARGET_NAMESPACES is '!all': all namespaces will be targeted"
    TARGET_NAMESPACES=""
fi

OPERATORGROUP=$(oc -n "$INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)

if [[ $(echo "$OPERATORGROUP" | wc -w) -gt 1 ]]; then
    echo "Error: multiple OperatorGroups in namespace \"$INSTALL_NAMESPACE\": $OPERATORGROUP" 1>&2
    oc -n "$INSTALL_NAMESPACE" get operatorgroup -o yaml >"$ARTIFACT_DIR/operatorgroups-$INSTALL_NAMESPACE.yaml"
    exit 1
elif [[ -n "$OPERATORGROUP" ]]; then
    echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    oc -n "$INSTALL_NAMESPACE" get operatorgroup "$OPERATORGROUP" -o yaml >"$ARTIFACT_DIR/og-$OPERATORGROUP-orig.yaml"
    OG_OPERATION=apply
    OG_NAMESTANZA="name: $OPERATORGROUP"
else
    echo "OperatorGroup does not exist: creating it"
    OG_OPERATION=create
    OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
    oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $INSTALL_NAMESPACE
spec:
  targetNamespaces: [$TARGET_NAMESPACES]
EOF
)

echo "OperatorGroup name is \"$OPERATORGROUP\""
echo "Creating CatalogSource"

CATSRC=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  generateName: oo-
  namespace: $INSTALL_NAMESPACE
spec:
  sourceType: grpc
  image: "$INDEX_IMAGE"
EOF
)

echo "CatalogSource name is \"$CATSRC\""

DEPLOYMENT_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "Set the deployment start time: ${DEPLOYMENT_START_TIME}"

echo "Creating Subscription"

SUB=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  generateName: oo-
  namespace: $INSTALL_NAMESPACE
spec:
  name: $PACKAGE
  channel: "$CHANNEL"
  source: $CATSRC
  sourceNamespace: $INSTALL_NAMESPACE
EOF
)

echo "Subscription name is \"$SUB\""
echo "Waiting for ClusterServiceVersion to become ready..."

for _ in $(seq 1 60); do
    CSV=$(oc -n "$INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"

            DEPLOYMENT_ART="oo_deployment_details.yaml"
            echo "Saving deployment details in ${DEPLOYMENT_ART} as a shared artifact"
            cat > "${ARTIFACT_DIR}/${DEPLOYMENT_ART}" <<EOF
---
csv: "${CSV}"
operatorgroup: "${OPERATORGROUP}"
subscription: "{SUB}"
catalogsource: "${CATSRC}"
install_namespace: "${INSTALL_NAMESPACE}"
target_namespaces: "${TARGET_NAMESPACES}"
deployment_start_time: "${DEPLOYMENT_START_TIME}"
EOF
            cp "${ARTIFACT_DIR}/${DEPLOYMENT_ART}" "${SHARED_DIR}/${DEPLOYMENT_ART}"
            exit 0
        fi
    fi
    sleep 10
done

echo "Timed out waiting for csv to become ready"

NS_ART="$ARTIFACT_DIR/ns-$INSTALL_NAMESPACE.yaml"
echo "Dumping Namespace $INSTALL_NAMESPACE as $NS_ART"
oc get namespace "$INSTALL_NAMESPACE" -o yaml >"$NS_ART"

OG_ART="$ARTIFACT_DIR/og-$OPERATORGROUP.yaml"
echo "Dumping OperatorGroup $OPERATORGROUP as $OG_ART"
oc get -n "$INSTALL_NAMESPACE" operatorgroup "$OPERATORGROUP" -o yaml >"$OG_ART"

CS_ART="$ARTIFACT_DIR/cs-$CATSRC.yaml"
echo "Dumping CatalogSource $CATSRC as $CS_ART"
oc get -n "$INSTALL_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$CS_ART"
for field in message reason; do
    VALUE="$(oc get -n "$INSTALL_NAMESPACE" catalogsource "$CATSRC" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  CatalogSource $CATSRC status $field: $VALUE"
    fi
done

SUB_ART="$ARTIFACT_DIR/sub-$SUB.yaml"
echo "Dumping Subscription $SUB as $SUB_ART"
oc get -n "$INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$SUB_ART"
for field in state reason; do
    VALUE="$(oc get -n "$INSTALL_NAMESPACE" subscription "$SUB" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  Subscription $SUB status $field: $VALUE"
    fi
done

if [[ -n "$CSV" ]]; then
    CSV_ART="$ARTIFACT_DIR/csv-$CSV.yaml"
    echo "ClusterServiceVersion $CSV was created but never became ready"
    echo "Dumping ClusterServiceVersion $CSV as $CSV_ART"
    oc get -n "$INSTALL_NAMESPACE" csv "$CSV" -o yaml >"$CSV_ART"
    for field in phase message reason; do
        VALUE="$(oc get -n "$INSTALL_NAMESPACE" csv "$CSV" -o jsonpath="{.status.$field}" || true)"
        if [[ -n "$VALUE" ]]; then
            echo "  ClusterServiceVersion $CSV status $field: $VALUE"
        fi
    done
else
    CSV_ART="$ARTIFACT_DIR/$INSTALL_NAMESPACE-all-csvs.yaml"
    echo "ClusterServiceVersion was never created"
    echo "Dumping all ClusterServiceVersions in namespace $INSTALL_NAMESPACE to $CSV_ART"
    oc get -n "$INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"
fi
exit 1
