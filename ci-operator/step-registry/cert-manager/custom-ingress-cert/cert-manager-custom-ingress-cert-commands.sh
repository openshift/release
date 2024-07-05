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

TMP_DIR=/tmp/cert-manager-ingress-commands-tmp-dir
mkdir -p $TMP_DIR
cd $TMP_DIR

INGRESS_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
CERT_NAME=custom-ingress-cert
oc create -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: openshift-ingress
spec:
  commonName: "*.$INGRESS_DOMAIN"
  dnsNames:
  - "*.$INGRESS_DOMAIN"
  usages:
  - server auth
  issuerRef:
    kind: ClusterIssuer
    name: $CLUSTERISSUER_NAME
  secretName: cert-manager-managed-ingress-cert-tls
# privateKey:
#   rotationPolicy: Always # Venafi need this
  duration: 2h
  renewBefore: 1h30m
EOF

# Wait for the certificate status to become ready
MAX_RETRY=30
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking the $CERT_NAME certificate status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers certificate $CERT_NAME -n openshift-ingress)" =~ True ]]; then
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The $CERT_NAME certificate status is still not ready after $((MAX_RETRY * INTERVAL)) seconds."
        echo "Dumping the certificate status:"
        oc get certificate $CERT_NAME -n openshift-ingress -o jsonpath='{.status}'
        echo "Dumping the challenge status:"
        oc get challenge -n openshift-ingress -o wide
        exit 1
    fi
    sleep $INTERVAL
done

# TODO in future: check whether needed to oc patch proxy when the certificate is not issued by the trusted Let's Encrypt product env

OLD_PROGRESSING_TIME="$(oc get co ingress '-o=jsonpath={.status.conditions[?(@.type=="Progressing")].lastTransitionTime}')"
oc patch ingresscontroller.operator default --type=merge -p '{"spec":{"defaultCertificate": {"name": "cert-manager-managed-ingress-cert-tls"}}}' -n openshift-ingress-operator
# Wait for the ingress pods to finish rollout
MAX_RETRY=12
INTERVAL=10
COUNTER=0
while :;
do
    NEW_PROGRESSING="$(oc get co ingress '-o=jsonpath={.status.conditions[?(@.type=="Progressing")]}')"
    if [[ "$NEW_PROGRESSING" =~ '"status":"False"' ]] && [[ ! "$NEW_PROGRESSING" =~ lastTransitionTime\":\"$OLD_PROGRESSING_TIME ]]; then
        echo "The ingress pods finished rollout." && break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The ingress pods still do not finish rollout after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get po -n openshift-ingress
        exit 1
    fi
    sleep $INTERVAL
done

echo "Validating the cert-manager customized default ingress certificate"
oc extract secret/cert-manager-managed-ingress-cert-tls -n openshift-ingress
CA_FILE=ca.crt
if [ ! -f ca.crt ]; then
    CA_FILE=tls.crt
fi
CANARY_ROUTE=$(oc get route canary -n openshift-ingress-canary -o=jsonpath='{.status.ingress[?(@.routerName=="default")].host}')
CURL_OUTPUT=$(curl -IsS --cacert $CA_FILE --connect-timeout 30 "https://$CANARY_ROUTE" 2>&1 || true)
if [[ ! "$CURL_OUTPUT" =~ HTTP/1.1\ 200\ OK ]]; then
    echo -e "Fails to validate the cert-manager customized default ingress certificate. Dumping the curl output:\n${CURL_OUTPUT}."
    exit 1
fi

# Update KUBECONFIG WRT CA of ingress certificate otherwise oc login command will fail
cp "$KUBECONFIG" "$KUBECONFIG".before-custom-ingress.bak
oc config view --minify --raw --kubeconfig "$KUBECONFIG".before-custom-ingress.bak > "$KUBECONFIG"
grep certificate-authority-data "$KUBECONFIG" | awk '{print $2}' | base64 -d > origin-ca.crt
cat $CA_FILE >> origin-ca.crt
NEW_CA_DATA=$(base64 -w0 origin-ca.crt)
sed -i "s/certificate-authority-data:.*$/certificate-authority-data: $NEW_CA_DATA/" "$KUBECONFIG"
echo "[$(date -u --rfc-3339=seconds)] The KUBECONFIG content is updated with CA of new default ingress certificate."
