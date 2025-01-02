#!/bin/bash

set -e
set -u
set -o pipefail

timestamp() {
    date -u --rfc-3339=seconds
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
fi

# Check if the catalogsource is ready to use
if [[ ! "$(oc get catalogsource $UPGRADE_CATSRC -n openshift-marketplace -o=jsonpath='{.status.connectionState.lastObservedState}')" == "READY" ]]; then
    echo "The CatalogSource $UPGRADE_CATSRC status is not ready"
    exit 1
fi

# Define common variables
SUB="openshift-cert-manager-operator"
OPERATOR_NAMESPACE="cert-manager-operator"
OPERAND_NAMESPACE="cert-manager"
ISSUER="sanity-upgrade-selfsigned"
CERTIFICATE="sanity-upgrade-selfsigned-cert"
TEST_NAMESPACE="test-cert-manager-upgrade"
INTERVAL=10

# Prepare the sanity test data for post-upgrade check

echo "# Creating a namespace for test usage."
oc create ns $TEST_NAMESPACE

echo "# Creating a self-signed issuer."
ISSUER_MANIFEST=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: $ISSUER
  namespace: $TEST_NAMESPACE
spec:
  selfSigned: {}
EOF
)
oc create -f - <<< "${ISSUER_MANIFEST}"

echo "# Waiting for the issuer to become ready."
MAX_RETRY=12
COUNTER=0
while :;
do
    echo "Checking the issuer $ISSUER status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers issuer $ISSUER -n $TEST_NAMESPACE)" =~ True ]]; then
        echo "[$(timestamp)] The issuer has become ready."
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The issuer status is still not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get issuer $ISSUER -n $TEST_NAMESPACE -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

# Perform the upgrade process

echo -e "# Patching the subscription with catalogsource '$UPGRADE_CATSRC' and channel '$UPGRADE_CHANNEL'."
oc patch subscription "${SUB}" -n $OPERATOR_NAMESPACE --type merge --patch '{"spec":{"source":"'"${UPGRADE_CATSRC}"'","channel":"'"${UPGRADE_CHANNEL}"'"}}'

# Set the 'UPGRADE_CSV' to the latest CSV if 'UPGRADE_CSV' is empty
if [ -z "${UPGRADE_CSV}" ]; then
    LATEST_CSV=$(oc get packagemanifest -n openshift-marketplace -l "catalog=$UPGRADE_CATSRC" --field-selector "metadata.name=$SUB" -o=jsonpath='{.items[0].status.channels[?(@.name=="'"${UPGRADE_CHANNEL}"'")].currentCSV}')
    UPGRADE_CSV=$LATEST_CSV
    echo -e "Will upgrade to the latest CSV '$LATEST_CSV' of the channel '$UPGRADE_CHANNEL' as the UPGRADE_CSV is not set."
fi

echo "# Waiting for the upgrade process to complete."
while :;
do
    INSTALLED_CSV=$(oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status.installedCSV}' || true)
    if [[ "$INSTALLED_CSV" == "${UPGRADE_CSV}" ]]; then
        echo "[$(timestamp)] Finished the upgarde process. The CSV is upgraded to $UPGRADE_CSV."
        break
    fi

    echo "## Waiting for a new installPlan to show up, then approving it."
    MAX_RETRY=12
    COUNTER=0
    while :;
    do
        INSTALL_PLAN=$(oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status.installplan.name}' || true)
        echo "Checking installPlan the #${COUNTER}-th time ..."
        if [[ -n "$INSTALL_PLAN"  && "$(oc get installplan $INSTALL_PLAN -n $OPERATOR_NAMESPACE -o=jsonpath='{.spec.approved}')" == "false" ]]; then
            oc patch installplan "${INSTALL_PLAN}" -n $OPERATOR_NAMESPACE --type merge --patch '{"spec":{"approved":true}}'
            echo "[$(timestamp)] The installPlan $INSTALL_PLAN is approved"
            break
        fi
        ((++COUNTER))
        if [[ $COUNTER -eq $MAX_RETRY ]]; then
            echo "[$(timestamp)] The installPlan didn't show up after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
            oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status}'
            exit 1
        fi
        sleep $INTERVAL
    done

    echo "## Waiting for the CSV status to be ready."
    MAX_RETRY=30
    COUNTER=0
    while :;
    do
        CSV=$(oc get installplan $INSTALL_PLAN -n $OPERATOR_NAMESPACE -o=jsonpath='{.spec.clusterServiceVersionNames[0]}' || true)
        echo "Checking CSV $CSV status for the #${COUNTER}-th time ..."
        if [[ "$(oc get csv "$CSV" -n $OPERATOR_NAMESPACE -o=jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "[$(timestamp)] The CSV $CSV status becomes ready"
            break
        fi
        ((++COUNTER))
        if [[ $COUNTER -eq $MAX_RETRY ]]; then
            echo "[$(timestamp)] The CSV $CSV status is not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
            oc get csv "$CSV" -n $OPERATOR_NAMESPACE -o=jsonpath='{.status}'
            oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status}'
            exit 1
        fi
        sleep $INTERVAL
    done
done

echo "# Waiting for the operand pods status to be ready."
MAX_RETRY=30
COUNTER=0
while :;
do
    echo "Checking cert-manager pods status for the #${COUNTER}-th time ..."
    if [ "$(oc get pod -n $OPERAND_NAMESPACE -o=jsonpath='{.items[*].status.phase}')" == "Running Running Running" ]; then
        echo "[$(timestamp)] Finished the cert-manager operator upgrade. The operand pods are all ready."
        oc get pod -n $OPERAND_NAMESPACE
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The cert-manager pods are not all ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get pod -n $OPERAND_NAMESPACE
        exit 1
    fi
    sleep $INTERVAL
done

# Post-upgrade check

echo "# Creating a certificate referring the pre-upgrade created issuer."
CERT_MANIFEST=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERTIFICATE
  namespace: $TEST_NAMESPACE
spec:
  isCA: true
  commonName: $CERTIFICATE
  subject:
    organizations:
      - Red Hat
  issuerRef:
    kind: Issuer
    name: $ISSUER
  secretName: ${CERTIFICATE}-tls
  privateKey:
    algorithm: ECDSA
    size: 256
EOF
)
oc create -f - <<< "${CERT_MANIFEST}"

echo "# Waiting for the certificate to become ready."
MAX_RETRY=12
COUNTER=0
while :;
do
    echo "Checking the certificate $CERTIFICATE status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers certificate $CERTIFICATE -n $TEST_NAMESPACE)" =~ True ]]; then
        echo "[$(timestamp)] The certificate has become ready."
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The certificate status is still not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get certificate $CERTIFICATE -n $TEST_NAMESPACE -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

echo "# Deleting the namespace as post-upgrade check finished."
oc delete ns $TEST_NAMESPACE
