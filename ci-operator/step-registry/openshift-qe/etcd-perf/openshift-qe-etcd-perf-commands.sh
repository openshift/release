#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
  #CASE 01 create 100 projects in the batches of 500
  #for i in {1..100}; do oc new-project project-$i;oc create configmap project-$i --from-file=/etc/pki/ca-trust/extracted/openssl/ca-bundle.trust.crt; done
  #for i in {1..500}; do oc new-project project-$i;oc -n project-$i create configmap project-$i --from-file=/etc/pki/ca-trust/source/anchors;done
  oc get cm/etcd-ca-bundle -n openshift-config -o=jsonpath='{.data.ca-bundle\.crt}' > /tmp/ca-bundle.crt
  for i in {1..5}; do oc new-project project-$i;oc -n project-$i create configmap project-$i --from-file=/tmp/ca-bundle.crt;done
  date;oc adm top node
  echo "to check endpoint health after creating many projects"
  for i in ` oc -n openshift-etcd get pods | grep etcd-ip |awk '{print $1}'`; do oc -n openshift-etcd exec $i -- etcdctl endpoint health; done
  #CASE 02 Many images
   if ! oc get ns |grep multi-image >/dev/null;
    then
      oc create ns multi-image;
   fi
  cat<<EOF>/tmp/template_image.yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: img-template
objects:
  - kind: Image
    apiVersion: image.openshift.io/v1
    metadata:
      name: "${NAME}"
      creationTimestamp:
    dockerImageReference: registry.redhat.io/ubi8/ruby-27:latest
    dockerImageMetadata:
      kind: DockerImage
      apiVersion: '1.0'
      Id: ''
      ContainerConfig: {}
      Config: {}
    dockerImageLayers: []
    dockerImageMetadataVersion: '1.0'
parameters:
  - name: NAME
EOF
  #for i in {1..30000}; do oc -n multi-image process -f /tmp/template_image.yaml -p NAME=testImage-$i | oc -n multi-image create -f - ; done
  for i in {1..3}; do oc -n multi-image process -f /tmp/template_image.yaml -p NAME=testImage-$i | oc -n multi-image create -f - ; done
  echo "to check endpoint health after creating many images"
  for i in ` oc -n openshift-etcd get pods | grep etcd-ip |awk '{print $1}'`; do oc -n openshift-etcd exec $i -- etcdctl endpoint health; done
  #CASE 03 Many secrets; 300namespaces each with 400 secrets

  #for i in {1..50}; do oc new-project sproject-$i; for j in {1..100}; do oc -n sproject-$i create secret generic my-secret-$j --from-literal=key1=supersecret --from-literal=key2=topsecret;done  done
  for i in {1..5}; do oc new-project sproject-$i; for j in {1..2}; do oc -n sproject-$i create secret generic my-secret-$j --from-literal=key1=supersecret --from-literal=key2=topsecret;done  done
  #---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  # Configure the name of the secret and namespace
  oc create ns my-namespace
  SECRET_NAME="my-large-secret"
  NAMESPACE="my-namespace"

  # SSH key
  ssh-keygen -t rsa -b 4096 -f sshkey -N ''
  SSH_PRIVATE_KEY=$(cat sshkey | base64 | tr -d '\n')
  SSH_PUBLIC_KEY=$(cat sshkey.pub | base64 | tr -d '\n')

  # Token (example token here, replace with your actual token generation method)
  TOKEN_VALUE=$(openssl rand -hex 32 | base64 | tr -d '\n')
  export TOKEN_VALUE
  # Self-signed Certificate
  openssl req -x509 -newkey rsa:4096 -keyout tls.key -out tls.crt -days 365 -nodes -subj "/CN=mydomain.com"
  CERTIFICATE=$(cat tls.crt | base64 | tr -d '\n')
  export CERTIFICATE
  PRIVATE_KEY=$(cat tls.key | base64 | tr -d '\n')
  export PRIVATE_KEY
  cat<<EOF>/tmp/testsec.yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: img-template
objects:
  - kind: Image
    apiVersion: image.openshift.io/v1
    metadata:
      name: "${NAME}"
      creationTimestamp:
    dockerImageReference: registry.redhat.io/ubi8/ruby-27:latest
    dockerImageMetadata:
      kind: DockerImage
      apiVersion: '1.0'
      Id: ''
      ContainerConfig: {}
      Config: {}
    dockerImageLayers: []
    dockerImageMetadataVersion: '1.0'
parameters:
  - name: NAME
EOF
oc -n multi-image create -f /tmp/testsec.yaml
  rm -f sshkey sshkey.pub tls.crt tls.key
  git clone https://github.com/peterducai/etcd-tools.git;sleep 10;
  #To check the etcd pod load status
  #for i in {3..12500}; do oc create secret generic ${SECRET_NAME}-$i -n $NAMESPACE --from-literal=ssh-private-key="$SSH_PRIVATE_KEY" --from-literal=ssh-public-key="$SSH_PUBLIC_KEY" --from-literal=token="TOKEN_VALUE" --from-literal=tls.crt="CERTIFICATE" --from-literal=tls.key="$PRIVATE_KEY";done
  for i in {3..12}; do oc create secret generic ${SECRET_NAME}-$i -n $NAMESPACE --from-literal=ssh-private-key="$SSH_PRIVATE_KEY" --from-literal=ssh-public-key="$SSH_PUBLIC_KEY" --from-literal=token="TOKEN_VALUE" --from-literal=tls.crt="CERTIFICATE" --from-literal=tls.key="$PRIVATE_KEY";done

  echo "to check endpoint health after creating many secrets"

  #------for i in ` oc -n openshift-etcd get pods | grep etcd-ip |awk '{print $1}'`; do oc -n openshift-etcd exec $i -- etcdctl endpoint health; done
  date;oc adm top node;date;etcd-tools/etcd-analyzer.sh;date
  #Fio Test STARTS...........................................................................!
  #etcd-tools/fio_suite.sh
  #-------etc_masternode1=`oc get node |grep master|awk '{print $1}'|tail -1`
  #------oc debug -n openshift-etcd --quiet=true node/$etc_masternode1 -- chroot host bash -c "podman run --privileged --volume /var/lib/etcd:/test quay.io/peterducai/openshift-etcd-suite:latest fio"
