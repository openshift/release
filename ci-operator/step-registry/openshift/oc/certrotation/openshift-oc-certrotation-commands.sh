#!/bin/bash
set -xeuo pipefail
oc adm wait-for-stable-cluster --minimum-stable-period=5s
# Let's start with the MCO cert rotation
oc adm ocp-certificates regenerate-machine-config-server-serving-cert
# A few preparatory rotations
oc adm ocp-certificates regenerate-leaf -n openshift-config-managed secrets kube-controller-manager-client-cert-key kube-scheduler-client-cert-key
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver-operator secrets node-system-admin-client
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver secrets check-endpoints-client-cert-key control-plane-node-admin-client-cert-key  external-loadbalancer-serving-certkey internal-loadbalancer-serving-certkey kubelet-client localhost-recovery-serving-certkey localhost-serving-cert-certkey service-network-serving-certkey
oc adm wait-for-stable-cluster

# Regenerating the Internal CA for Ingress
proxyKey="temProxy.key"
proxyCert="temProxy.pem"
cusIngressKey="wilcard.key"
cusIngressCsr="wildcard.csr"
cusIngressCert="wildcard.pem"
keyLength=4096
baseDomin=$(oc get dns.config cluster -o=jsonpath='{.spec.baseDomain}')
defaultIngressDomin=$(oc get ingresscontroller default  -o=jsonpath='{.status.domain}' -n openshift-ingress-operator)
currentPath=$(pwd)
workPath="/tmp/replcertforingress"
sudo mkdir $workPath; sudo chmod 664 $workPath; cd $workPath
echo "[cus]" >> tem.conf
echo "subjectAltName = DNS:*.$defaultIngressDomin" >> tem.conf

## create root ca for cluster proxy and certification for default ingress controller
openssl req -newkey rsa:$keyLength -nodes -sha256 -keyout $proxyKey -x509 -days 30 -subj "/CN=$baseDomin" -out $proxyCert
openssl genrsa -out $cusIngressKey $keyLength
openssl req -new -key $cusIngressKey  -subj "/CN=$defaultIngressDomin" -addext "subjectAltName = DNS:*.$defaultIngressDomin" -out  $cusIngressCsr
openssl x509 -req -days 30 -CA $proxyCert -CAkey $proxyKey -CAserial caproxy.srl -CAcreateserial -extfile  tem.conf -extensions cus -in $cusIngressCsr -out $cusIngressCert

## create a config map and update the cluster-wide proxy configuration with the newly created config map
oc create configmap custom-ca --from-file=ca-bundle.crt=$workPath/$proxyCert -n openshift-config
oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

## create secret and update the Ingress Controller configuration with the newly created secret
oc create secret tls custom-secret --cert=$workPath/$cusIngressCert --key=$workPath/$cusIngressKey -n openshift-ingress
oc patch ingresscontroller.operator default --type=merge -p '{"spec":{"defaultCertificate": {"name": "custom-secret"}}}' -n openshift-ingress-operator

## Delete the router-ca secret.
oc -n openshift-ingress-operator delete secrets/router-ca

## remove workPath folder
cd $currentPath; sudo rm -rf $workPath

## restart the Ingress Operator
oldPod=$(oc -n openshift-ingress-operator get pods  -l name=ingress-operator -o=jsonpath='{.items[0].metadata.name}')
oldRouterCaTime=$(oc -n openshift-ingress-operator get secrets/router-ca -o=jsonpath='{.metadata.creationTimestamp}')
oc -n openshift-ingress-operator delete pods -l name=ingress-operator
oc adm wait-for-stable-cluster

## check if new ingress-operator pod and new secret router-ca are created or not
newPod=$(oc -n openshift-ingress-operator get pods  -l name=ingress-operator -o=jsonpath='{.items[0].metadata.name}')
newRouterCaTime=$(oc -n openshift-ingress-operator get secrets/router-ca -o=jsonpath='{.metadata.creationTimestamp}')
if [ -z "$newPod" ] || [ X"$newPod" == X"$oldPod" ]
then
    echo "new ingress controller pod is not created or old ingress controller pod is not deleted" && exit 1
fi
if [ -z "$newRouterCaTime" ] || [ X"$newRouterCaTime" == X"$oldRouterCaTime" ]
then
    echo "new secret router-ca is not created or old secret router-ca is not deleted" && exit 1
fi
