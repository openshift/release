#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__cso-qe-test__quay-tests-cso-qe-test.xml
    ' EXIT
fi

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: container-security-operator
  namespace: openshift-operators
spec:
  channel: ${CSO_CHANNEL}
  installPlanApproval: Automatic
  name: container-security-operator
  source: ${CSO_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

typeset -i waitIdx=0
typeset csv=""
for ((waitIdx = 1; waitIdx <= 60; waitIdx++)); do
    csv="$(oc -n openshift-operators get sub container-security-operator -o jsonpath='{.status.installedCSV}' || true)"
    if [[ -n "${csv}" ]]; then
        if [[ "$(oc -n openshift-operators get csv "${csv}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            break
        fi
    fi
    sleep 10
done

#execute sanity test
##create ns
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-cso
EOF
sleep 2

set +x
typeset robotUsername robotPassword
robotUsername="$(cat /var/run/quayio-pull-robot/username)"
robotPassword="$(cat /var/run/quayio-pull-robot/password)"
set -x

oc -n test-cso create secret docker-registry cso-private \
    --docker-server=quay.io \
    --docker-username="${robotUsername}" \
    --docker-password="${robotPassword}"
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

for ((waitIdx = 1; waitIdx <= 60; waitIdx++)); do
    if [[ "$(oc -n test-cso get deployment nodejs-sample -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
        break
    fi
    sleep 15
done

##check IMV
typeset imv=""
for ((waitIdx = 1; waitIdx <= 60; waitIdx++)); do
    imv="$(oc -n test-cso get imagemanifestvuln sha256.14237f12c482dcca294e766fc57163d0c0adac43ae690d1328fdc578f4792b95 || true)"
    if [[ -n "${imv}" ]]; then
        exit 0
    fi
    sleep 10
done

true
