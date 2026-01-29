#!/bin/bash

set -x

HC_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HC_NAME
hcp_ns="${HC_NS}-${HC_NAME}"
export hcp_ns

# Installing hypershift cli
HYPERSHIFT_CLI_NAME=hcp

echo "$(date) Installing hypershift cli"
mkdir /tmp/${HYPERSHIFT_CLI_NAME}_cli
downloadURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_CLI_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz ${downloadURL}
tar -xvf /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz -C /tmp/${HYPERSHIFT_CLI_NAME}_cli
chmod +x /tmp/${HYPERSHIFT_CLI_NAME}_cli/${HYPERSHIFT_CLI_NAME}
export PATH=$PATH:/tmp/${HYPERSHIFT_CLI_NAME}_cli

echo "$(date) Triggering the hosted cluster ${HC_NAME} deletion"
${HYPERSHIFT_CLI_NAME} destroy cluster kubevirt --name ${HC_NAME} --namespace ${HC_NS}
echo "$(date) Hosted cluster ${HC_NAME} deletion is successful"
