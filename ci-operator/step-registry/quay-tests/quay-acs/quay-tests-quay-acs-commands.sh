#!/bin/bash
set -euo pipefail

cat <<EOF
# Deploy ACS operator (with default settings):
#     Installation mode: All namespaces
#     Installation namespace: rhacs-operator
#     channel: stable
#     Central & Secured Cluster: default values in "stackrox" project
EOF

#env vars
export ACS_NAMESPACE="rhacs-operator"           #ACS default Namespace
export ACS_CHANNEL="$ACS_OPERATOR_CHANNEL"      #default stable
export CENTRAL_NAMESPACE="stackrox"  #stackrox project for Central & SecuredClusters
export ROX_ENDPOINT
export ROX_API_TOKEN

# Deploy ACS operator
function deploy_acs_operator() {
  echo "Deploy ACS in default Namespace: ${ACS_NAMESPACE}"
   
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ACS_NAMESPACE}
EOF

  #Create ACS operator group
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quayacsgrp
  namespace: ${ACS_NAMESPACE}
EOF

#Create ACS operator Subscription
SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhacs-operator
  namespace: ${ACS_NAMESPACE}
spec:
  installPlanApproval: Automatic
  name: rhacs-operator
  channel: $ACS_OPERATOR_CHANNEL
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)
  echo "The ACS Operator subscription is $SUB"

  #check ACS operator pod status
  for i in {1..60}; do
    CSV=$(oc -n ${ACS_NAMESPACE} get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n ${ACS_NAMESPACE} get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ACS ClusterServiceVersion \"$CSV\" is ready"
            break
        fi
    fi
    sleep 15
    echo "Wait for ACS operator ready $((i*15))s"
  done
  echo "ACS Operator is deployed successfully"   

}


function retry() {
  for (( i = 0; i < 10; i++ )); do
    "$@" && return 0
    sleep 30
  done
  return 1
}

function wait_deploy() {
  retry oc -n ${CENTRAL_NAMESPACE} rollout status deploy/"$1" --timeout=300s \
    || {
      echo "oc logs -n ${CENTRAL_NAMESPACE} --selector=app==$1 --pod-running-timeout=30s --tail=20"
      oc logs -n ${CENTRAL_NAMESPACE} --selector="app==$1" --pod-running-timeout=30s --tail=20
      exit 1
    }
}

#Deploy Central
function deploy_acs_central() {

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${CENTRAL_NAMESPACE}
EOF

   cat <<EOF | oc apply -f -
kind: Central
apiVersion: platform.stackrox.io/v1alpha1
metadata:
  name: stackrox-central-services
  namespace: ${CENTRAL_NAMESPACE}
spec:
  central:
    exposure:
      route:
        enabled: true
EOF
  
   sleep 120

   #check Central CR deployed status
   central_cr_name=$(oc get Central -n ${CENTRAL_NAMESPACE} -o jsonpath='{.items[0].metadata.name}')
   oc wait Central "${central_cr_name}" --for=condition=Deployed=true  --timeout=360s  -n ${CENTRAL_NAMESPACE}
   echo "Central is deployed successfully..."
}

#Generating and applying an init bundle for RHACS 
function generate_init_bundle() {
  
   #check roxctl availability
   roxctl version

   #totally 6 steps to init bundle
   #1, get central admin password from central-htpasswd
   oc -n ${CENTRAL_NAMESPACE} get secret central-htpasswd -o go-template='{{index .data "password" | base64decode}}'>central_htpasswd
   central_htpasswd=$(cat central_htpasswd)
   echo "fetch central admin password successfully..."

   #2, get central route
   oc get route -n ${CENTRAL_NAMESPACE} central -o jsonpath='{.spec.host}'>ROX_ENDPOINT
   ROX_ENDPOINT=$(cat ROX_ENDPOINT)
   
   #3, get StackRox API Admin token
   curl -sk -u "admin:${central_htpasswd}" "https://${ROX_ENDPOINT}/v1/apitokens/generate" -d '{"name":"quayacs", "role": "Admin"}' | jq -r '.token'>ROX_API_TOKEN
   ROX_API_TOKEN=$(cat ROX_API_TOKEN)
   
   #4, generate init bundle yaml
   export ROX_CENTRAL_ADDRESS="${ROX_ENDPOINT}:443"
   export ROX_API_TOKEN="${ROX_API_TOKEN}"

   roxctl -e "$ROX_CENTRAL_ADDRESS" central init-bundles generate quay-acs --output-secrets acs_cluster_init_bundle.yaml --insecure-skip-tls-verify

   #5, apply init bundle yaml
   oc create -f acs_cluster_init_bundle.yaml -n ${CENTRAL_NAMESPACE}
   echo "init bundle is generated successfully..."
    
   #6, copy central files to "${ARTIFACT_DIR}/" folder for archive
   # cp central_htpasswd "${ARTIFACT_DIR}"
   cp acs_cluster_init_bundle.yaml "${ARTIFACT_DIR}"

   # Central url for archive   
   echo https://${ROX_ENDPOINT}>"${ARTIFACT_DIR}"/central_route

}

#Deploy SecuredCluster
function deploy_acs_secured_cluster() {
   echo "start to deploy secured cluster..."
   cat <<EOF | oc apply -f -
kind: SecuredCluster   
apiVersion: platform.stackrox.io/v1alpha1
metadata:
  name: stackrox-secured-cluster-services
  namespace: ${CENTRAL_NAMESPACE}
spec:
  clusterName: my-cluster
EOF
   sleep 90
   
   #Check SecuredCluster deploy status
   securedcluster_name=$(oc get SecuredCluster -n ${CENTRAL_NAMESPACE} -o jsonpath='{.items[0].metadata.name}')
   oc wait SecuredCluster "${securedcluster_name}" --for=condition=Deployed=true  --timeout=360s  -n ${CENTRAL_NAMESPACE}
   echo "SecuredCluster is deployed successfully..."

   #Wait for pod starting and vulnerability scan
   sleep 120   
}

#Quay violations creteria: Deployment:quay, Severity: High & Critical
function generate_quay_violation_report() {
    echo "Generating quay violation report"
    curl -k -X GET -H "Authorization: Bearer ${ROX_API_TOKEN}"  -H "Content-Type: application/json" \
    https://${ROX_ENDPOINT}/v1/alerts?query=Severity%3AHigh%2CCritical%2BDeployment%3Aquay | jq > "${ARTIFACT_DIR}"/quay_acs_violations.json
   
}

#Get and archive each vulnerability with id
function generate_vuln_id_detail_report() {

    echo "Generating vulnerability detail report"
    mkdir -p "${ARTIFACT_DIR}"/detail
      
    curl -k -X GET -H "Authorization: Bearer ${ROX_API_TOKEN}"  -H "Content-Type: application/json" \
     https://${ROX_ENDPOINT}/v1/alerts?query=Category%3AVulnerability%20Management%2BDeployment%3Aquay%2BSeverity%3AHigh%2CCritical  | jq > quay_acs_detail_violations
     
    vulnnum=$(cat quay_acs_detail_violations | jq '.alerts' | jq 'length')
    if [ "$vulnnum" -lt 1 ]; then
        echo "No High && Critical vulnerability found for Quay in 'Vulnerability Management' Category"
        exit 0
    fi

    echo "get vulnerability by id"
    jq -r '.alerts|.[]|.id'<quay_acs_detail_violations | while read req
    do
        vulnname=$(jq -r -c --arg req "$req" '.alerts|.[]|select(.id == $req)|.deployment.name' <quay_acs_detail_violations)
        curl -k -X GET -H "Authorization: Bearer ${ROX_API_TOKEN}"  -H "Content-Type: application/json" \
        https://${ROX_ENDPOINT}/v1/alerts/$req | jq > "${ARTIFACT_DIR}/detail/${req}_${vulnname}"
    done
}

function deploy_acs_operator_default_setting() {

   deploy_acs_operator

   deploy_acs_central
   echo ">>> Wait for 'stackrox-central-services' deployments"
   wait_deploy central-db
   wait_deploy central

   generate_init_bundle

   deploy_acs_secured_cluster
   echo ">>> Wait for 'stackrox-secured-cluster-services' deployments"
   wait_deploy admission-control
   wait_deploy scanner
   wait_deploy scanner-db
   wait_deploy sensor

  # Artifacts archiv into ${ARTIFACT_DIR}/ folder, detail violation report in detail/ folder
   sleep 180 # wait for vulnerability scan
   generate_quay_violation_report
   generate_vuln_id_detail_report

}

   echo "ACS violations scan start..."  
   deploy_acs_operator_default_setting || true
   echo "Quay image violations scanning with ACS is done successfully"

