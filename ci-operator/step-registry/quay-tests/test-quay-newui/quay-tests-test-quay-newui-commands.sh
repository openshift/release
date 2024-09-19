#!/bin/bash

set -euo pipefail

#Get the credentials and Email of new Quay User
#QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
#QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
#QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)
QUAY_USERNAME="quay"
QUAY_PASSWORD="password"

#Set Kubeconfig:
cd new-ui-tests 
skopeo -v
oc version
terraform version
(cp -L $KUBECONFIG /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR


function copyArtifacts {
    JUNIT_PREFIX="junit_"
    cp -r ./cypress/results/* $ARTIFACT_DIR
    for file in "$ARTIFACT_DIR"/*; do
        if [[ ! "$(basename "$file")" =~ ^"$JUNIT_PREFIX" ]]; then
            mv "$file" "$ARTIFACT_DIR"/"$JUNIT_PREFIX""$(basename "$file")"
        fi
    done
    cp -r ./cypress/videos/* $ARTIFACT_DIR
    cp -r ./cypress/logs/* $ARTIFACT_DIR

    if [[ -e "./quay_new_ui_testing_report.xml" ]]; then
        cp -r "./quay_new_ui_testing_report.xml" $ARTIFACT_DIR
    fi

    if [[ -e "./quay_new_ui_testing_report_before_format.xml" ]]; then
        cp -r "./quay_new_ui_testing_report_before_format.xml" $ARTIFACT_DIR
    fi
}

function reformat_report { 

      ReportFileNameOrg=$1
      ReportFileName=${ReportFileNameOrg%\.*}
      ReportType=$2

      echo "ReportFileName = $ReportFileName" 
      echo "ReportType = $ReportType"  

      sed '/testsuite name=\"Root Suite\"/d'  ${ReportFileName}.xml  > ${ReportFileName}_v1.xml
  
      TotalTCNum=$(awk -F'"' '/<testsuites/ {print $6}' ${ReportFileName}_v1.xml)
      FailedTCNum=$(awk -F'"' '/<testsuites/ {print $2}' ${ReportFileName}_v1.xml)
      SikppedTCNum=$(grep "<testsuite .*/>" ${ReportFileName}_v1.xml|wc -l|sed 's/ //g')
      RunTCNum=$(expr $TotalTCNum - $SikppedTCNum)

      echo "TotalTCNum   = $TotalTCNum"
      echo "FailedTCNum  = $FailedTCNum"
      echo "SikppedTCNum = $SikppedTCNum"
      echo "RunTCNum     = $RunTCNum"

      sed -i '4,$ {/<testsuite /d}' ${ReportFileName}_v1.xml
      sed -i '4,$ {/<\/testsuite>/d}' ${ReportFileName}_v1.xml
      sed -i '$i  </testsuite>' ${ReportFileName}_v1.xml
      sed -i "3s/OCP-[0-9]*/${ReportType}/g" ${ReportFileName}_v1.xml
      sed -i '3s/time="[0-9.]*"//g' ${ReportFileName}_v1.xml

      sed -i "2s/$TotalTCNum/$RunTCNum/g"  ${ReportFileName}_v1.xml
      sed -i -r "3s/(tests=\")[0-9]*(\"[ ]*failures=\")[0-9]*(\")/\1${RunTCNum}\2${FailedTCNum}\3/g"  ${ReportFileName}_v1.xml

      mv ${ReportFileName}.xml ${ReportFileName}_before_format.xml
      mv ${ReportFileName}_v1.xml  ${ReportFileName}.xml
}

# Install Dependcies defined in packages.json
yarn install || true
yarn add --dev typescript || true
yarn add --dev cypress-failed-log || true
yarn add --dev @cypress/grep || true

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

# Cypress Doc https://docs.cypress.io/guides/references/proxy-configuration
if [ "${QUAY_PROXY}" = "true" ]; then
    HTTPS_PROXY=$(cat $SHARED_DIR/proxy_public_url)
    export HTTPS_PROXY
    HTTP_PROXY=$(cat $SHARED_DIR/proxy_public_url)
    export HTTP_PROXY
fi

#Trigget Quay NEW UI E2E Testing
set +x
quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
echo "The Quay hostname is $quay_route"
quay_hostname=${quay_route#*//}
echo "The Quay hostname is $quay_hostname"

#curl -k -X POST $quay_route/api/v1/user/initialize --header 'Content-Type: application/json' --data '{"username": "'$QUAY_USERNAME'", "password": "'$QUAY_PASSWORD'", "email": "'$QUAY_EMAIL'", "access_token": true }' | jq '.access_token' | tr -d '"' | tr -d '\n' > "$SHARED_DIR"/quay_oauth2_token || true

quay_access_token=$(cat $SHARED_DIR/quay_oauth2_token|tr -d '\n')
echo "The Quay super user access token is ${quay_access_token}" 

ocp_endpoint=$(cat $SHARED_DIR/kubeconfig|grep "server:"|awk '{print $2}'|tr -d '\n')
echo "The OCP cluster endpoint is ${ocp_endpoint}"
ocp_kubeadmin_password=$(cat $SHARED_DIR/kubeadmin-password |tr -d '\n')
echo "The OCP cluster kubeadmin password is ${ocp_kubeadmin_password}"

export CYPRESS_QUAY_ENDPOINT=${quay_hostname}
export CYPRESS_QUAY_ENDPOINT_PROTOCOL=https
export CYPRESS_QUAY_SUPER_USER_NAME=${QUAY_USERNAME}
export CYPRESS_QUAY_SUPER_USER_PASSWORD=${QUAY_PASSWORD}
export CYPRESS_QUAY_SUPER_USER_TOKEN=${quay_access_token}
export CYPRESS_OCP_ENDPOINT=${ocp_endpoint}
export CYPRESS_OCP_PASSWORD=${ocp_kubeadmin_password}
export CYPRESS_QUAY_PROJECT=quay-enterprise

#yarn run cypress run --browser firefox --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json --env grepTags=newui+-nopipeline || true
yarn run cypress run --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json --env grepTags='newui --noprowci' || true

yarn run jrm  ./quay_new_ui_testing_report.xml ./cypress/results/quay_new_ui_testing_report-* || true

reformat_report "quay_new_ui_testing_report.xml" "Quay New UI Testing" ||true 

