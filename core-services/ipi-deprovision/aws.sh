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
		timeout --signal=SIGTERM 30m hypershift destroy infra aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --infra-id "${INFRA_ID}" --base-domain "${HYPERSHIFT_BASE_DOMAIN}" --region "${REGION}" || touch "${WORKDIR}/failure"
		timeout --signal=SIGTERM 30m hypershift destroy iam aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --infra-id "${INFRA_ID}" --region "${REGION}" || touch "${WORKDIR}/failure"
	else
		timeout --signal=SIGTERM 60m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
	fi
}

function strip_finalizers() {
	local resource="${1}" ns="${2}"
	oc get "${resource}" -n "${ns}" -o json 2>/dev/null | \
		jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' | \
		while read -r obj; do
			[[ -n "${obj}" ]] && oc patch "${resource}" "${obj}" -n "${ns}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
		done
}

function deletion_age_seconds() {
	local ns="${1}" name="${2}"
	local ts
	ts="$(oc get hostedcluster "${name}" -n "${ns}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")"
	if [[ -z "${ts}" ]]; then
		echo "0"
		return
	fi
	local now deletion
	now="$(date +%s)"
	deletion="$(date -d "${ts}" +%s 2>/dev/null || echo "${now}")"
	echo $(( now - deletion ))
}

# hypershift_force_cleanup uses tiered finalizer removal based on how long
# the HC has been in deletion. The pruner cron runs every 15min, so each
# invocation evaluates the deletion age and runs ONLY the highest applicable
# tier. This avoids wasting time on lower-level cleanup when the HC has been
# stuck long enough to justify escalation.
#
# Tier 4 (>=2hr):    HC and NodePool finalizers (last resort, skips all lower tiers)
# Tier 3 (>=1.5hr):  delete CP namespace if not already deleting
# Tier 2 (>=1hr):    HCP + CAPI resource finalizers
# Tier 1 (>=30min):  awsmachine finalizers + terminate EC2 instances
function hypershift_force_cleanup() {
	local hc_ns="${1}" hc_name="${2}"
	local hcp_ns="${hc_ns}-${hc_name}"

	local infra_id region
	infra_id="$(oc get hostedcluster -n "${hc_ns}" "${hc_name}" -o jsonpath='{.spec.infraID}' 2>/dev/null || echo "")"
	region="$(oc get hostedcluster -n "${hc_ns}" "${hc_name}" -o jsonpath='{.spec.platform.aws.region}' 2>/dev/null || echo "")"
	: "${infra_id:=${hc_name}}"
	: "${region:=us-east-1}"

	# Ensure HC has a deletion timestamp
	oc delete hostedcluster "${hc_name}" -n "${hc_ns}" --wait=false 2>/dev/null || true

	local age
	age="$(deletion_age_seconds "${hc_ns}" "${hc_name}")"
	echo "Force-cleaning ${hc_ns}/${hc_name} (infraID=${infra_id} region=${region} age=${age}s)"

	if [[ ${age} -ge 7200 ]]; then
		# Tier 4 (>=2hr): strip HC and NodePool finalizers as last resort
		echo "  Tier 4 (>=2hr): HC + NodePool finalizers (skipping lower tiers)"
		oc delete nodepool --all -n "${hc_ns}" --wait=false 2>/dev/null || true
		strip_finalizers nodepool "${hc_ns}"
		strip_finalizers hostedcluster "${hc_ns}"
	elif [[ ${age} -ge 5400 ]]; then
		# Tier 3 (>=1.5hr): delete CP namespace if not already deleting
		echo "  Tier 3 (>=1.5hr): CP namespace"
		local ns_ts
		ns_ts="$(oc get namespace "${hcp_ns}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")"
		if [[ -z "${ns_ts}" ]]; then
			echo "    Deleting CP namespace ${hcp_ns}"
			oc delete namespace "${hcp_ns}" --wait=false 2>/dev/null || true
		fi
	elif [[ ${age} -ge 3600 ]]; then
		# Tier 2 (>=1hr): strip HCP and CAPI resource finalizers
		echo "  Tier 2 (>=1hr): HCP + CAPI finalizers"
		for resource in machineset.cluster.x-k8s.io machinedeployment.cluster.x-k8s.io cluster.cluster.x-k8s.io awsendpointservice hostedcontrolplane; do
			oc delete "${resource}" --all -n "${hcp_ns}" --wait=false 2>/dev/null || true
			strip_finalizers "${resource}" "${hcp_ns}"
		done
	elif [[ ${age} -ge 1800 ]]; then
		# Tier 1 (>=30min): strip awsmachine finalizers + terminate EC2 instances
		echo "  Tier 1 (>=30min): awsmachine finalizers + EC2 termination"
		oc delete awsmachine --all -n "${hcp_ns}" --wait=false 2>/dev/null || true
		oc delete machine.cluster.x-k8s.io --all -n "${hcp_ns}" --wait=false 2>/dev/null || true
		strip_finalizers awsmachine "${hcp_ns}"
		strip_finalizers machine.cluster.x-k8s.io "${hcp_ns}"

		local -a instance_ids
		readarray -t instance_ids < <(aws ec2 describe-instances --region "${region}" \
			--filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
			--query 'Reservations[].Instances[].InstanceId' --output json 2>/dev/null | jq -r '.[]' 2>/dev/null || true)
		if [[ ${#instance_ids[@]} -gt 0 && -n "${instance_ids[0]}" ]]; then
			echo "    Terminating EC2 instances: ${instance_ids[*]}"
			aws ec2 terminate-instances --region "${region}" --instance-ids "${instance_ids[@]}" || true
		fi
	fi

	# Always attempt direct AWS infra/IAM cleanup
	local hs_base_domain="${HYPERSHIFT_BASE_DOMAIN:-origin-ci-int-aws.dev.rhcloud.com}"
	local force_rc=0
	timeout --signal=SIGTERM 30m hypershift destroy infra aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --infra-id "${infra_id}" --base-domain "${hs_base_domain}" --region "${region}" || force_rc=1
	timeout --signal=SIGTERM 30m hypershift destroy iam aws --aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" --infra-id "${infra_id}" --region "${region}" || force_rc=1
	return "${force_rc}"
}

function hypershift_pruner() {
	local had_failure=0
	local failed_clusters=()

	local hostedclusters
	if [[ -n ${HYPERSHIFT_PRUNER_ALL_NAMESPACES:-} ]]; then
		hostedclusters="$(oc get hostedcluster -A -o json | jq -r --argjson timestamp 14400 '.items[] | select (.metadata.creationTimestamp | sub("\\..*";"Z") | sub("\\s";"T") | fromdate < now - $timestamp) | .metadata.namespace + "/" + .metadata.name')"
	else
		hostedclusters="$(oc get hostedcluster -n clusters -o json | jq -r --argjson timestamp 14400 '.items[] | select (.metadata.creationTimestamp | sub("\\..*";"Z") | sub("\\s";"T") | fromdate < now - $timestamp).metadata.name')"
	fi

	if [[ -z "${hostedclusters}" ]]; then
		echo "No stale HostedClusters found."
		return 0
	fi

	for hostedcluster in ${hostedclusters}; do
		local hc_ns hc_name
		if [[ -n ${HYPERSHIFT_PRUNER_ALL_NAMESPACES:-} ]]; then
			hc_ns="${hostedcluster%%/*}"
			hc_name="${hostedcluster##*/}"
		else
			hc_ns="clusters"
			hc_name="${hostedcluster}"
		fi

		echo "Destroying HostedCluster: ${hc_ns}/${hc_name}"
		if ! timeout --signal=SIGTERM 30m hypershift destroy cluster aws \
			--aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" \
			--namespace "${hc_ns}" --name "${hc_name}" \
			--cluster-grace-period 15m; then
			echo "ERROR: graceful destroy failed for ${hc_ns}/${hc_name}, forcing cleanup ..."
			failed_clusters+=("${hc_ns}/${hc_name}")
		fi
	done

	for failed_hc in "${failed_clusters[@]+"${failed_clusters[@]}"}"; do
		local fc_ns="${failed_hc%%/*}" fc_name="${failed_hc##*/}"
		hypershift_force_cleanup "${fc_ns}" "${fc_name}" || had_failure=$((had_failure+1))
	done

	if [[ ${had_failure} -ne 0 ]]; then
		echo "HyperShift pruner: ${had_failure} force-cleanup(s) had failures."
		return 1
	fi
}

function vpc_has_only_orphaned_eni() {
	local region="${1}" vpc_id="${2}"

	local enis
	enis="$(aws ec2 describe-network-interfaces \
		--region "${region}" \
		--filters "Name=vpc-id,Values=${vpc_id}" \
		--query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description,Subnet:SubnetId,Type:InterfaceType,RequesterManaged:RequesterManaged}' \
		--output json)"

	local total
	total="$(echo "${enis}" | jq 'length')"
	if [[ "${total}" -ne 1 ]]; then
		return 1
	fi

	local requester_managed
	requester_managed="$(echo "${enis}" | jq -r '.[0].RequesterManaged')"
	if [[ "${requester_managed}" != "true" ]]; then
		return 1
	fi

	local interface_type
	interface_type="$(echo "${enis}" | jq -r '.[0].Type')"

	local owner_gone=false
	case "${interface_type}" in
		network_load_balancer|gateway_load_balancer)
			local lb_count
			lb_count="$(aws elbv2 describe-load-balancers \
				--region "${region}" \
				--query "length(LoadBalancers[?VpcId=='${vpc_id}'])" \
				--output text)"
			if [[ "${lb_count}" -eq 0 ]]; then
				owner_gone=true
			fi
			;;
		*)
			return 1
			;;
	esac

	if [[ "${owner_gone}" != "true" ]]; then
		return 1
	fi

	echo "WARNING: Known AWS bug -- orphaned ENI in VPC ${vpc_id} (region ${region})."
	echo "WARNING: The ENI is RequesterManaged but its owning resource (${interface_type}) no longer exists:"
	echo "${enis}" | jq -r '.[0] | "  ENI: \(.Id)  Type: \(.Type)  Status: \(.Status)  Subnet: \(.Subnet)  Description: \(.Desc)"'
	echo "WARNING: Skipping deprovision for this VPC."
	return 0
}

if [[ -n ${HYPERSHIFT_PRUNER:-} ]]; then
	hypershift_pruner_rc=0
	hypershift_pruner || hypershift_pruner_rc=$?
fi

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"

aws_cluster_age_cutoff="$(TZ=":Africa/Abidjan" date --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M+0000')"
echo "deprovisioning clusters with an expirationDate before ${aws_cluster_age_cutoff} in AWS ..."
# --region is necessary when there is no profile customization
for region in $( aws ec2 describe-regions --region us-east-1 --query "Regions[].{Name:RegionName}" --output text ); do
	echo "deprovisioning in AWS region ${region} ..."
	aws ec2 describe-vpcs --output json --region ${region} | jq --arg date "${aws_cluster_age_cutoff}" -r '.Vpcs[] | select(.Tags[]? | select(.Key == "expirationDate" and .Value < $date)) | . as $vpc | .Tags[]? | select((.Key | startswith("kubernetes.io/cluster/")) and (.Value == "owned")) | "\($vpc.VpcId) \(.Key)"' > /tmp/clusters
	while read vpc_id cluster; do
		if vpc_has_only_orphaned_eni "${region}" "${vpc_id}"; then
			continue
		fi
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

# IAM user cleanup (ci-op-* older than 72h)
cutoff="$(date -u -d '72 hours ago' --iso-8601=seconds)"
aws iam list-users --query "Users[?starts_with(UserName, 'ci-op-') && CreateDate < '${cutoff}'].UserName" --output text | tr '\t' '\n' | while read -r user; do
	if [[ -n "$user" ]]; then
		echo "Cleaning IAM user: $user"
		aws iam list-attached-user-policies --user-name "$user" --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | while read -r policy; do
			[[ -n "$policy" ]] && aws iam detach-user-policy --user-name "$user" --policy-arn "$policy" || true
		done
		aws iam list-user-policies --user-name "$user" --query 'PolicyNames[]' --output text | tr '\t' '\n' | while read -r policy; do
			[[ -n "$policy" ]] && aws iam delete-user-policy --user-name "$user" --policy-name "$policy" || true
		done
		aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text | tr '\t' '\n' | while read -r key; do
			[[ -n "$key" ]] && aws iam delete-access-key --user-name "$user" --access-key-id "$key" || true
		done
		aws iam list-groups-for-user --user-name "$user" --query 'Groups[].GroupName' --output text | tr '\t' '\n' | while read -r group; do
			[[ -n "$group" ]] && aws iam remove-user-from-group --user-name "$user" --group-name "$group" || true
		done
		aws iam delete-user --user-name "$user" && echo "✓ Deleted: $user"
	fi
done

FAILED="$(find ${clusters} -name failure -printf '%H\n' | sort)"
final_rc=0

if [[ -n "${FAILED}" ]]; then
	echo "Deprovision failed on the following clusters:"
	xargs --max-args 1 basename <<< "$FAILED"
	final_rc=1
fi

if [[ -n ${HYPERSHIFT_PRUNER:-} ]] && [[ ${hypershift_pruner_rc:-0} -ne 0 ]]; then
	echo "HyperShift pruner had failures (rc=${hypershift_pruner_rc})."
	final_rc=1
fi

if [[ ${final_rc} -ne 0 ]]; then
	exit 1
fi

echo "Deprovision finished successfully"
