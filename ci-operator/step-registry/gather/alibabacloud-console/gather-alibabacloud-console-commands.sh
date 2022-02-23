#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
echo "${KUBECONFIG}"

if test -f "${KUBECONFIG}"
then
    oc --request-timeout=5s -n openshift-machine-api get machines -o go-template='{{range .items}}{{.status.providerStatus.instanceId}}{{"\n"}}{{end}}' >> "${TMPDIR}/node-provider-IDs.txt" &
	wait "$!"
else
	echo "No kubeconfig; skipping providerID extraction."
fi

if test -s "${SHARED_DIR}/alibaba-instance-ids.txt"
then
	cat "${SHARED_DIR}/alibaba-instance-ids.txt" >> "${TMPDIR}/node-provider-IDs.txt"
else
	echo "No alibaba-instance-ids.txt; skipping console log retrieval."
fi

if test ! -s "${TMPDIR}/node-provider-IDs.txt"
then
    echo "No node-provider-IDs found. Exiting."
	exit 0
fi

pushd /tmp

export ALIBABA_CLI_CREDENTIALS_FILE="${SHARED_DIR}/config"

wget https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz -O aliyun-cli.tgz
tar zxvf aliyun-cli.tgz
popd

/tmp/aliyun version

echo "Settting --config-path=${ALIBABA_CLI_CREDENTIALS_FILE} and --region=${LEASED_RESOURCE}"
/tmp/aliyun --config-path "${ALIBABA_CLI_CREDENTIALS_FILE}" configure set --region "${LEASED_RESOURCE}"

cat "${TMPDIR}/node-provider-IDs.txt" | sort | grep . | uniq | while read -r INSTANCE_ID
do
	echo "Gathering console logs for ${INSTANCE_ID}"
        /tmp/aliyun --config-path "${ALIBABA_CLI_CREDENTIALS_FILE}" ecs GetInstanceConsoleOutput --RegionId "${LEASED_RESOURCE}" --InstanceId "$INSTANCE_ID" | jq -r '.ConsoleOutput' | base64 -d > "${ARTIFACT_DIR}/${INSTANCE_ID}" &
	wait "$!"
done
