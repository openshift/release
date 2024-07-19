#!/bin/bash

set -e
set -u
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTERISSUER_NAME=cluster-certs-clusterissuer
if [[ ! "$(oc get --no-headers clusterissuer $CLUSTERISSUER_NAME)" =~ True ]]; then
    echo "The prerequsite clusterissuer $CLUSTERISSUER_NAME is not ready. Please ensure the cert-manager-clusterissuer ref is executed first."
    exit 1
fi

TMP_DIR=/tmp/cert-manager-api-commands-tmp-dir
mkdir -p $TMP_DIR
cd $TMP_DIR

# Apiserver uses port 6443 in convention. Therefore we configure "port: 6443" for the alternative Apiserver FQDN (NEW_API_FQDN) too.
oc create -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: cert-manager-managed-alt-apiserver
  namespace: openshift-kube-apiserver
spec:
  ports:
    - name: https
      port: 6443
      protocol: TCP
      targetPort: 6443
  selector:
    apiserver: "true"
  type: LoadBalancer
EOF

# Wait for the LoadBalancer service status to become ready
MAX_RETRY=20
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking the LoadBalancer service's status for the #${COUNTER}-th time ..."
    EXTERNAL_IP_OUTPUT=$(oc get service cert-manager-managed-alt-apiserver -n openshift-kube-apiserver -o jsonpath='{.status.loadBalancer.ingress}')
    if grep -q '"ip"' <<< "$EXTERNAL_IP_OUTPUT"; then
        EXTERNAL_IP=$(oc get service cert-manager-managed-alt-apiserver -n openshift-kube-apiserver -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        RECORD_TYPE=A
        break
    elif grep -q '"hostname"' <<< "$EXTERNAL_IP_OUTPUT"; then
        EXTERNAL_IP=$(oc get service cert-manager-managed-alt-apiserver -n openshift-kube-apiserver -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        RECORD_TYPE=CNAME
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The LoadBalancer service's status does not show either ip or hostname after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get service cert-manager-managed-alt-apiserver -n openshift-kube-apiserver -o jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

BASE_DOMAIN=$(oc get dns cluster -o=jsonpath='{.spec.baseDomain}')
ORIGINAL_API_FQDN=$(oc whoami --show-server | sed -e 's|https://||' -e 's/:6443//')
NEW_API_FQDN=alt-api.${BASE_DOMAIN}

oc create -f - << EOF
apiVersion: ingress.operator.openshift.io/v1
kind: DNSRecord
metadata:
  name: cert-manager-managed-alt-apiserver
  namespace: openshift-ingress-operator
spec:
  dnsManagementPolicy: Managed
  dnsName: "${NEW_API_FQDN}."
  recordTTL: 30
  recordType: ${RECORD_TYPE}
  targets:
  - ${EXTERNAL_IP}
EOF

# Wait for the dnsrecord status to become ready
MAX_RETRY=12
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking the cert-manager-managed-alt-apiserver dnsrecord status for the #${COUNTER}-th time ..."
    DNSRECORD_STATUS="$(oc get dnsrecord cert-manager-managed-alt-apiserver -n openshift-ingress-operator '-o=jsonpath={.status.zones[*].conditions[?(@.type=="Published")].status}')"
    if [[ ! "$DNSRECORD_STATUS" =~ False ]]; then
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The cert-manager-managed-alt-apiserver dnsrecord status is still not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get dnsrecord cert-manager-managed-alt-apiserver -n openshift-ingress-operator -o jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

CERT_NAME=alt-api-cert
oc create -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: openshift-config
spec:
  commonName: "$NEW_API_FQDN"
  dnsNames:
  - "$NEW_API_FQDN"
  usages:
  - server auth
  issuerRef:
    kind: ClusterIssuer
    name: $CLUSTERISSUER_NAME
  secretName: cert-manager-managed-alt-api-tls
# privateKey:
#   rotationPolicy: Always # Venafi required this
  duration: 2h
  renewBefore: 1h30m
EOF

# Wait for the certificate status to become ready
MAX_RETRY=15
INTERVAL=20
COUNTER=0
while :;
do
    echo "Checking the $CERT_NAME certificate status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers certificate $CERT_NAME -n openshift-config)" =~ True ]]; then
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The $CERT_NAME certificate status is still not ready after $((MAX_RETRY * INTERVAL)) seconds."
        echo "Dumping the certificate status:"
        oc get certificate $CERT_NAME -n openshift-config -o jsonpath='{.status}'
        echo "Dumping the challenge status:"
        oc get challenge -n openshift-config -o wide
        exit 1
    fi
    sleep $INTERVAL
done

# The CA_FILE will be used later to update KUBECONFIG
oc extract secret/cert-manager-managed-alt-api-tls -n openshift-config
CA_FILE=ca.crt
if [ ! -f ca.crt ]; then
    CA_FILE=tls.crt
fi

oc patch apiserver cluster --type=merge -p "
spec:
  servingCerts:
    namedCertificates:
    - names:
      - $NEW_API_FQDN
      servingCertificate:
        name: cert-manager-managed-alt-api-tls
"

# Wait for the clusteroperator kube-apiserver to start rollout
# Note, if $NEW_API_FQDN is $ORIGINAL_API_FQDN other than an alternative FQDN, all oc commands afterwards need to add the --insecure-skip-tls-verify flag before the KUBECONFIG is updated later
MAX_RETRY=20
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking if clusteroperator kube-apiserver rollout has started for the #${COUNTER}-th time ..."
    if [ "$(oc get clusteroperator kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" == True ]; then
        echo "The clusteroperator kube-apiserver Progressing status becomes True, indicates rollout has started." && break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The clusteroperator kube-apiserver rollout did not start after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get clusteroperator kube-apiserver -o=jsonpath='{.status.conditions[?(@.type=="Progressing")]}'
        exit 1
    fi
    sleep $INTERVAL
done

MAX_RETRY=50 # kube-apiserver rollout needs long time
INTERVAL=30
COUNTER=0
while :;
do
    echo "Checking if clusteroperator kube-apiserver rollout finished for the #${COUNTER}-th time ..."
    if [ "$(oc get --no-headers clusteroperator kube-apiserver | awk '{print $3 $4 $5}')" == TrueFalseFalse ]; then
        echo 'The clusteroperator kube-apiserver status becomes "True False False", indicates rollout finished.' && break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The clusteroperator kube-apiserver status is not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get clusteroperator kube-apiserver -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

echo "Validating the cert-manager customized Apiserver serving certificate."
MAX_RETRY=12
INTERVAL=10
COUNTER=0
while :;
do
    CURL_OUTPUT=$(curl -IsS -v --cacert $CA_FILE --connect-timeout 30 "https://$NEW_API_FQDN:6443" 2>&1 || true)
    if [[ "$CURL_OUTPUT" =~ "HTTP/2 403" ]]; then
        echo "The customized certificate is serving as expected." && break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo -e "Timeout after $((MAX_RETRY * INTERVAL)) seconds waiting for curl validation succeeded. Dumping the curl output:\n${CURL_OUTPUT}."
        exit 1
    fi
    sleep $INTERVAL
done

# Update KUBECONFIG WRT CA of Apiserver certificate
cp "$KUBECONFIG" "$KUBECONFIG".before-custom-api.bak
oc config view --minify --raw --kubeconfig "$KUBECONFIG".before-custom-api.bak > "$KUBECONFIG"
grep certificate-authority-data "$KUBECONFIG" | awk '{print $2}' | base64 -d > origin-ca.crt
cat $CA_FILE >> origin-ca.crt
NEW_CA_DATA=$(base64 -w0 origin-ca.crt)
sed -i "s/certificate-authority-data:.*$/certificate-authority-data: $NEW_CA_DATA/" "$KUBECONFIG"
sed -i "s/$ORIGINAL_API_FQDN/$NEW_API_FQDN/" "$KUBECONFIG" # In case NEW_API_FQDN != ORIGINAL_API_FQDN
echo "[$(date -u --rfc-3339=seconds)] The KUBECONFIG content is updated with CA of new Apiserver certificate."

echo "Validating the updated KUBECONFIG using any oc command."
oc get po -n openshift-kube-apiserver -L revision -l apiserver
