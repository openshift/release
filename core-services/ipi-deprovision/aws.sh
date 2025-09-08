#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

trap finish TERM QUIT

function finish {
	CHILDREN=$(jobs -p)
	if test -n "${CHILDREN}"; then
		kill ${CHILDREN} && wait
	fi
	exit # since bash doesn't handle SIGQUIT, we need an explicit "exit"
}

function queue() {
	local LIVE="$(jobs | wc -l)"
	while [[ "${LIVE}" -ge 2 ]]; do
		sleep 1
		LIVE="$(jobs | wc -l)"
	done
	echo "${@}"
	"${@}" &
}

function deprovision() {
	WORKDIR="${1}"
	REGION="$(cat ${WORKDIR}/metadata.json|jq .aws.region -r)"
	INFRA_ID="$(cat ${WORKDIR}/metadata.json|jq '.aws.identifier[0]|keys[0]' -r|cut -d '/' -f3|tr -d '\n')"
	if [[ -n ${HYPERSHIFT_PRUNER:-} ]]; then
		HYPERSHIFT_BASE_DOMAIN="${HYPERSHIFT_BASE_DOMAIN:-origin-ci-int-aws.dev.rhcloud.com}"
		timeout --signal=SIGQUIT 30m hypershift destroy infra aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --infra-id "${INFRA_ID}" --base-domain "${HYPERSHIFT_BASE_DOMAIN}" --region "${REGION}" || touch "${WORKDIR}/failure"
		timeout --signal=SIGQUIT 30m hypershift destroy iam aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --infra-id "${INFRA_ID}" --region "${REGION}" || touch "${WORKDIR}/failure"
	else
		timeout --signal=SIGQUIT 60m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
	fi
}

if [[ -n ${HYPERSHIFT_PRUNER:-} ]]; then
	had_failure=0
	hostedclusters="$(oc get hostedcluster -n clusters -o json | jq -r --argjson timestamp 14400 '.items[] | select (.metadata.creationTimestamp | sub("\\..*";"Z") | sub("\\s";"T") | fromdate < now - $timestamp).metadata.name')"
	for hostedcluster in $hostedclusters; do
		hypershift destroy cluster aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --namespace clusters --name "${hostedcluster}" || had_failure=$((had_failure+1))
	done
	# Exit here if we had errors, otherwise we destroy the OIDC providers for the hostedclusters and deadlock deletion as cluster api creds stop working so it will never be able to remove machine finalizers
	if [[ $had_failure -ne 0 ]]; then exit $had_failure; fi
fi

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"

aws_cluster_age_cutoff="$(TZ=":Africa/Abidjan" date --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M+0000')"
echo "deprovisioning clusters with an expirationDate before ${aws_cluster_age_cutoff} in AWS ..."
# --region is necessary when there is no profile customization
for region in $( aws ec2 describe-regions --region us-east-1 --query "Regions[].{Name:RegionName}" --output text ); do
	echo "deprovisioning in AWS region ${region} ..."
	aws ec2 describe-vpcs --output json --region ${region} | jq --arg date "${aws_cluster_age_cutoff}" -r '.Vpcs[] | select(.Tags[]? | select(.Key == "expirationDate" and .Value < $date)) | .Tags[]? | select((.Key | startswith("kubernetes.io/cluster/")) and (.Value == "owned")) | .Key' > /tmp/clusters
	while read cluster; do
		workdir="${logdir}/${cluster:22}"
		mkdir -p "${workdir}"
		cat <<-EOF >"${workdir}/metadata.json"
		{
			"aws":{
				"region":"${region}",
				"identifier":[
					{"${cluster}": "owned"}
				]
			}
		}
		EOF
		echo "will deprovision AWS cluster ${cluster} in region ${region}"
	done < /tmp/clusters
done

# log installer version for debugging purposes
openshift-install version

clusters=$( find "${logdir}" -mindepth 1 -type d )
for workdir in $(shuf <<< ${clusters}); do
	queue deprovision "${workdir}"
done

wait

FAILED="$(find ${clusters} -name failure -printf '%H\n' | sort)"
if [[ -n "${FAILED}" ]]; then
	echo "Deprovision failed on the following clusters:"
	xargs --max-args 1 basename <<< $FAILED
	exit 1
fi

echo "Deprovision finished successfully"
