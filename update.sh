#!/usr/bin/env bash

function install_operator() {
  local currentCSV catalogSource catalogSourceNamespace approval
  approval=${1:-Automatic}
  echo ">>> Install rhacs-operator"
  oc get packagemanifests rhacs-operator -o jsonpath="{range .status.channels[*]}Channel: {.name} currentCSV: {.currentCSV}{'\n'}{end}"
  currentCSV=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.channels[?(.name=='${OPERATOR_CHANNEL:-stable}')].currentCSV}")
  currentCSV=${OPERATOR_VERSION+rhacs-operator.v}${OPERATOR_VERSION:-${currentCSV}}
  catalogSource=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSource}")
  catalogSourceNamespace=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSourceNamespace}")
  echo "Add subscription"
  echo "
      apiVersion: operators.coreos.com/v1alpha1
      kind: Subscription
      metadata:
        name: rhacs-operator
        namespace: openshift-operators
      spec:
        channel: ${OPERATOR_CHANNEL:-stable}
        installPlanApproval: ${approval^}
        name: rhacs-operator
        source: ${catalogSource}
        sourceNamespace: ${catalogSourceNamespace}
        startingCSV: ${currentCSV## }
  " | sed -e 's/^    //' \
    | tee >(cat 1>&2) \
    | oc apply -f -
  OPERATOR_VERSION="${currentCSV}"
}

function approve_install_plan() {
  local subscription='subscription.operators.coreos.com/rhacs-operator'
  local plan
  echo "Wait for install plan."
  while true; do
    plan=$(oc -n openshift-operators get "${subscription}" -o jsonpath='{.status.installplan.name}' 2>/dev/null)
    if [[ $plan != '' ]]; then
      break
    fi
    printf "."
    sleep 1
  done
  set -x
  oc -n openshift-operators patch installPlan "${plan}" --type merge --patch '{"spec":{"approved":true}}'
}

RELEASE=4.6
OPERATOR_VERSION=${RELEASE%.*}.$(( ${RELEASE#*.} - 2 )).0
OPERATOR_VERSION=${RELEASE}.0
OPERATOR_CHANNEL=stable
set -x
install_operator Automatic
#approve_install_plan
#oc wait -A --for=condition=ready -lapp==rhacs-operator,control-plane=controller-manager pod
kubectl wait --for 'jsonpath={.status.state}=AtLatestKnown' sub rhacs-operator -n openshift-operators --timeout=3m
echo $?

## upgrade test
#oc -n openshift-operators patch subscription rhacs-operator -p '{"spec":{"installPlanApproval":"Automatic"}}' --type merge
#approve_install_plan

# watch operator upgrade logs
#oc -n openshift-operators logs deploy/rhacs-operator-controller-manager manager -f

# after central+cluster install,
# restart sensor to try to accelerate getting scanner results
#sleep 60
#oc rollout restart deployment sensor -n stackrox
