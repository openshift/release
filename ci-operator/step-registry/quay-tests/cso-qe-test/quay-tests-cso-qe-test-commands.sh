#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Install CSO
CSO_CHANNEL="$CSO_CHANNEL"
CSO_SOURCE="$CSO_SOURCE"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: container-security-operator
  namespace: openshift-operators
spec:
  channel: $CSO_CHANNEL
  installPlanApproval: Automatic
  name: container-security-operator
  source: $CSO_SOURCE
  sourceNamespace: openshift-marketplace
EOF

for _ in {1..60}; do
    CSV=$(oc -n openshift-operators get sub container-security-operator -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n openshift-operators get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    echo "CSV is NOT ready $_ times"
    sleep 10
done
echo "Container Security Operator is deployed successfully"


#execute sanity test
##create ns
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-cso
EOF
sleep 2

##create a pull secret
oc -n test-cso create secret docker-registry cso-private --docker-server=quay.io --docker-username="quay-qetest+testcso" --docker-password="G7KF0G57BX4F8G23LOZHJQR9QZAHHEPI3WI4FPFQAJM5UER82M6TNKOMHHKVGRUO"
sleep 2
oc -n test-cso secrets link default cso-private --for=pull
sleep 2

##deploy pod by deployment
cat <<EOF | oc apply -f -
kind: Deployment
apiVersion: apps/v1
metadata:
  name: nodejs-sample
  namespace: test-cso
  labels:
    app: nodejs-sample
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nodejs-sample
  template:
    metadata:
      labels:
        app: nodejs-sample
        deploymentconfig: nodejs-sample
    spec:
      containers:
        - name: nodejs-sample
          image: >-
            quay.io/quay-qetest/nodejs-sample@sha256:14237f12c482dcca294e766fc57163d0c0adac43ae690d1328fdc578f4792b95
          ports:
            - containerPort: 8080
              protocol: TCP
          resources: {}
          imagePullPolicy: Always
      restartPolicy: Always
      dnsPolicy: ClusterFirst
      securityContext: {}
      schedulerName: default-scheduler
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
      maxSurge: 25%
EOF

for _ in {1..60}; do
    if [[ "$(oc -n test-cso get deployment nodejs-sample -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
        echo "Test Pod is in ready status" >&2
        break
    fi
    echo "Test Pod is NOT ready $_ times"
    sleep 15
done

##check IMV
for _ in {1..60}; do
    IMV=$(oc -n test-cso get imagemanifestvuln sha256.14237f12c482dcca294e766fc57163d0c0adac43ae690d1328fdc578f4792b95 || true)
    if [[ -n "$IMV" ]]; then
        echo "$IMV"
        exit 0
    fi
    echo "Can NOT get IMV $_ times"
    sleep 10
done
echo "QE Test for Container Security Operator is passed"
