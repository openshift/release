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
	local resource="${1}" ns="${2}" filter_name="${3:-}"
	local items
	if [[ -n "${filter_name}" ]]; then
		items="$(oc get "${resource}" "${filter_name}" -n "${ns}" -o json 2>/dev/null || echo '{}')"
		if [[ "$(echo "${items}" | jq -r '.kind // empty' 2>/dev/null)" != "List" ]]; then
			items="$(echo "${items}" | jq '{items: [.]}')"
		fi
	else
		items="$(oc get "${resource}" -n "${ns}" -o json 2>/dev/null || echo '{"items":[]}')"
	fi
	echo "${items}" | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' | \
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
# Tier 4 (>=4hr):    HC and NodePool finalizers (last resort, skips all lower tiers)
# Tier 3 (>=3hr):    delete CP namespace if not already deleting
# Tier 2 (>=2hr):    HCP + CAPI resource finalizers
# Tier 1 (>=1hr):    awsmachine finalizers + terminate EC2 instances
function hypershift_force_cleanup() {
	local hc_ns="${1}" hc_name="${2}"
	local passed_infra_id="${3:-}" passed_region="${4:-}"
	local hcp_ns="${hc_ns}-${hc_name}"

	local infra_id region
	if [[ -n "${passed_infra_id}" ]]; then
		infra_id="${passed_infra_id}"
	else
		infra_id="$(oc get hostedcluster -n "${hc_ns}" "${hc_name}" -o jsonpath='{.spec.infraID}' 2>/dev/null || echo "")"
	fi
	if [[ -n "${passed_region}" ]]; then
		region="${passed_region}"
	else
		region="$(oc get hostedcluster -n "${hc_ns}" "${hc_name}" -o jsonpath='{.spec.platform.aws.region}' 2>/dev/null || echo "")"
	fi
	: "${infra_id:=${hc_name}}"
	: "${region:=us-east-1}"

	# Ensure HC has a deletion timestamp
	oc delete hostedcluster "${hc_name}" -n "${hc_ns}" --wait=false 2>/dev/null || true

	local age
	age="$(deletion_age_seconds "${hc_ns}" "${hc_name}")"
	echo "Force-cleaning ${hc_ns}/${hc_name} (infraID=${infra_id} region=${region} age=${age}s)"

	if [[ ${age} -ge 14400 ]]; then
		# Tier 4 (>=4hr): strip HC and NodePool finalizers as last resort
		echo "  Tier 4 (>=4hr): HC + NodePool finalizers (skipping lower tiers)"
		local -a np_names
		readarray -t np_names < <(oc get nodepool -n "${hc_ns}" -o json 2>/dev/null | \
			jq -r --arg hc "${hc_name}" '.items[] | select(.spec.clusterName == $hc) | .metadata.name' 2>/dev/null || true)
		for np in "${np_names[@]+"${np_names[@]}"}"; do
			[[ -z "${np}" ]] && continue
			oc delete nodepool "${np}" -n "${hc_ns}" --wait=false 2>/dev/null || true
			strip_finalizers nodepool "${hc_ns}" "${np}"
		done
		strip_finalizers hostedcluster "${hc_ns}" "${hc_name}"
	elif [[ ${age} -ge 10800 ]]; then
		# Tier 3 (>=3hr): delete CP namespace if not already deleting
		echo "  Tier 3 (>=3hr): CP namespace"
		local ns_ts
		ns_ts="$(oc get namespace "${hcp_ns}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")"
		if [[ -z "${ns_ts}" ]]; then
			echo "    Deleting CP namespace ${hcp_ns}"
			oc delete namespace "${hcp_ns}" --wait=false 2>/dev/null || true
		fi
	elif [[ ${age} -ge 7200 ]]; then
		# Tier 2 (>=2hr): strip HCP and CAPI resource finalizers
		echo "  Tier 2 (>=2hr): HCP + CAPI finalizers"
		for resource in machineset.cluster.x-k8s.io machinedeployment.cluster.x-k8s.io cluster.cluster.x-k8s.io awsendpointservice hostedcontrolplane; do
			oc delete "${resource}" --all -n "${hcp_ns}" --wait=false 2>/dev/null || true
			strip_finalizers "${resource}" "${hcp_ns}"
		done
	elif [[ ${age} -ge 3600 ]]; then
		# Tier 1 (>=1hr): strip awsmachine finalizers + terminate EC2 instances
		echo "  Tier 1 (>=1hr): awsmachine finalizers + EC2 termination"
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
	local profile_filter="${HYPERSHIFT_CLUSTER_PROFILE_FILTER:-}"

	local oc_ns_flag=( -n clusters )
	if [[ -n ${HYPERSHIFT_PRUNER_ALL_NAMESPACES:-} ]]; then
		oc_ns_flag=( -A )
	fi

	local hostedclusters
	hostedclusters="$(oc get hostedcluster "${oc_ns_flag[@]}" -o json \
		| jq -r \
			--argjson timestamp 14400 \
			--arg profile "${profile_filter}" \
			'.items[]
			| select(.metadata.creationTimestamp | sub("\\..*";"Z") | sub("\\s";"T") | fromdate < now - $timestamp)
			| select($profile == "" or .metadata.annotations["cluster-profile"] == $profile)
			| .metadata.namespace + "/" + .metadata.name')"

	if [[ -z "${hostedclusters}" ]]; then
		echo "No stale HostedClusters found."
		return 0
	fi

	for hostedcluster in ${hostedclusters}; do
		local hc_ns="${hostedcluster%%/*}"
		local hc_name="${hostedcluster##*/}"

		local hc_infra_id hc_region
		hc_infra_id="$(oc get hostedcluster "${hc_name}" -n "${hc_ns}" -o jsonpath='{.spec.infraID}' 2>/dev/null || echo "")"
		hc_region="$(oc get hostedcluster "${hc_name}" -n "${hc_ns}" -o jsonpath='{.spec.platform.aws.region}' 2>/dev/null || echo "")"

		echo "Destroying HostedCluster: ${hc_ns}/${hc_name}"
		if ! timeout --signal=SIGTERM 30m hypershift destroy cluster aws \
			--aws-creds "${AWS_SHARED_CREDENTIALS_FILE}" \
			--namespace "${hc_ns}" --name "${hc_name}" \
			--cluster-grace-period 15m; then
			echo "ERROR: graceful destroy failed for ${hc_ns}/${hc_name}, forcing cleanup ..."
			failed_clusters+=("${hc_ns}/${hc_name}|${hc_infra_id}|${hc_region}")
		fi
	done

	for failed_hc in "${failed_clusters[@]+"${failed_clusters[@]}"}"; do
		local fc_spec="${failed_hc%%|*}"
		local fc_rest="${failed_hc#*|}"
		local fc_infra_id="${fc_rest%%|*}"
		local fc_region="${fc_rest#*|}"
		local fc_ns="${fc_spec%%/*}" fc_name="${fc_spec##*/}"
		hypershift_force_cleanup "${fc_ns}" "${fc_name}" "${fc_infra_id}" "${fc_region}" || had_failure=$((had_failure+1))
	done

	if [[ ${had_failure} -ne 0 ]]; then
		echo "HyperShift pruner: ${had_failure} force-cleanup(s) had failures."
		return 1
	fi
}

function vpc_has_only_orphaned_eni() {
	local region="${1}" vpc_id="${2}" elbv2_json="${3:-}"

	# Without a valid elbv2 inventory, do not classify as orphan or skip the VPC.
	if [[ -z "${elbv2_json}" ]]; then
		return 1
	fi

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
			lb_count="$(echo "${elbv2_json}" | jq --arg vpc "${vpc_id}" '[.LoadBalancers[] | select(.VpcId == $vpc)] | length')"
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

function is_lb_not_found_error() {
	grep -qiE 'LoadBalancerNotFound|Cannot find load balancer|NoSuchEntity' <<<"${1}"
}

# Delete leftover ALB/NLB/GWLB and classic ELBs in a VPC using pre-fetched region LB lists.
# Returns 0 on success (nothing to delete, deletes ok, or not-found races).
# Returns 1 if any delete or deletion-confirmation failed for a reason other than not-found.
function delete_vpc_load_balancers() {
	local region="${1}" vpc_id="${2}" elbv2_json="${3}" classic_json="${4}"
	local arn name err failed=0
	local -a deleted_arns=() deleted_names=()

	while read -r arn; do
		[[ -z "${arn}" ]] && continue
		echo "deleting elbv2 load balancer ${arn} in ${region}"
		if ! err="$(aws elbv2 delete-load-balancer --region "${region}" --load-balancer-arn "${arn}" 2>&1)"; then
			if is_lb_not_found_error "${err}"; then
				echo "load balancer ${arn} already gone"
			else
				echo "ERROR: failed to delete elbv2 load balancer ${arn}: ${err}"
				failed=1
			fi
			continue
		fi
		deleted_arns+=( "${arn}" )
	done < <(echo "${elbv2_json}" | jq -r --arg vpc "${vpc_id}" '.LoadBalancers[]? | select(.VpcId == $vpc) | .LoadBalancerArn')

	while read -r name; do
		[[ -z "${name}" ]] && continue
		echo "deleting classic load balancer ${name} in ${region}"
		if ! err="$(aws elb delete-load-balancer --region "${region}" --load-balancer-name "${name}" 2>&1)"; then
			if is_lb_not_found_error "${err}"; then
				echo "classic load balancer ${name} already gone"
			else
				echo "ERROR: failed to delete classic load balancer ${name}: ${err}"
				failed=1
			fi
			continue
		fi
		deleted_names+=( "${name}" )
	done < <(echo "${classic_json}" | jq -r --arg vpc "${vpc_id}" '.LoadBalancerDescriptions[]? | select(.VPCId == $vpc) | .LoadBalancerName')

	if [[ ${#deleted_arns[@]} -gt 0 ]]; then
		echo "waiting for elbv2 load balancer deletion in ${region} ..."
		if ! aws elbv2 wait load-balancers-deleted --region "${region}" --load-balancer-arns "${deleted_arns[@]}"; then
			echo "ERROR: timed out waiting for elbv2 load balancers to delete in VPC ${vpc_id} (${region})"
			failed=1
		fi
	fi

	# Classic ELB has no deletion waiter; bound polling via describe-load-balancers.
	local attempt max_attempts=30
	for name in "${deleted_names[@]+"${deleted_names[@]}"}"; do
		[[ -z "${name}" ]] && continue
		attempt=0
		while true; do
			if err="$(aws elb describe-load-balancers --region "${region}" --load-balancer-names "${name}" 2>&1)"; then
				if [[ "${attempt}" -ge "${max_attempts}" ]]; then
					echo "ERROR: classic load balancer ${name} still present after wait in ${region}"
					failed=1
					break
				fi
				sleep 10
				attempt=$((attempt + 1))
				continue
			fi
			if is_lb_not_found_error "${err}"; then
				break
			fi
			echo "ERROR: failed to confirm classic load balancer ${name} deletion: ${err}"
			failed=1
			break
		done
	done

	return "${failed}"
}

if [[ -n ${HYPERSHIFT_PRUNER:-} ]]; then
	hypershift_pruner_rc=0
	hypershift_pruner || hypershift_pruner_rc=$?
fi

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"
inventory_dir="$(mktemp -d)"

aws_cluster_age_cutoff="$(TZ=":Africa/Abidjan" date --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M+0000')"
echo "deprovisioning clusters with an expirationDate before ${aws_cluster_age_cutoff} in AWS ..."

# Phase 1: collect LB inventories for every region. Failures must not become empty lists.
regions=( $( aws ec2 describe-regions --region us-east-1 --query "Regions[].{Name:RegionName}" --output text ) )
inventory_failed=0
for region in "${regions[@]}"; do
	echo "collecting load balancer inventory in AWS region ${region} ..."
	if ! aws elbv2 describe-load-balancers --region "${region}" --output json > "${inventory_dir}/elbv2-${region}.json"; then
		echo "ERROR: elbv2 describe-load-balancers failed in ${region}"
		inventory_failed=1
		rm -f "${inventory_dir}/elbv2-${region}.json"
		continue
	fi
	if ! aws elb describe-load-balancers --region "${region}" --output json > "${inventory_dir}/classic-${region}.json"; then
		echo "ERROR: elb describe-load-balancers failed in ${region}"
		inventory_failed=1
		rm -f "${inventory_dir}/elbv2-${region}.json" "${inventory_dir}/classic-${region}.json"
		continue
	fi
done

lb_cleanup_failed=0
if [[ "${inventory_failed}" -ne 0 ]]; then
	echo "ERROR: LB inventory incomplete; deferring installer destroy until inventories succeed"
else
	# Phase 2: only after all regional inventories succeeded, plan VPC cleanup + destroy.
	for region in "${regions[@]}"; do
		echo "deprovisioning in AWS region ${region} ..."
		elbv2_json="$(cat "${inventory_dir}/elbv2-${region}.json")"
		classic_json="$(cat "${inventory_dir}/classic-${region}.json")"
		clusters_file="${inventory_dir}/clusters-${region}.txt"
		aws ec2 describe-vpcs --output json --region ${region} | jq --arg date "${aws_cluster_age_cutoff}" -r '.Vpcs[] | select(.Tags[]? | select(.Key == "expirationDate" and .Value < $date)) | . as $vpc | .Tags[]? | select((.Key | startswith("kubernetes.io/cluster/")) and (.Value == "owned")) | "\($vpc.VpcId) \(.Key)"' > "${clusters_file}"
		while read vpc_id cluster; do
			if vpc_has_only_orphaned_eni "${region}" "${vpc_id}" "${elbv2_json}"; then
				continue
			fi
			if ! delete_vpc_load_balancers "${region}" "${vpc_id}" "${elbv2_json}" "${classic_json}"; then
				echo "ERROR: load balancer cleanup failed for VPC ${vpc_id} in ${region}; deferring destroy for ${cluster}"
				lb_cleanup_failed=1
				continue
			fi
			workdir="$(mktemp -d "${logdir}/cluster.XXXXXX")"
			jq -n --arg region "${region}" --arg cluster "${cluster}" \
				'{aws:{region:$region,identifier:[{($cluster):"owned"}]}}' \
				> "${workdir}/metadata.json"
			echo "will deprovision AWS cluster ${cluster} in region ${region}"
		done < "${clusters_file}"
	done
fi

rm -rf "${inventory_dir}"

# log installer version for debugging purposes
openshift-install version

clusters=()
while IFS= read -r -d '' workdir; do
	clusters+=( "${workdir}" )
done < <(find "${logdir}" -mindepth 1 -type d -print0 2>/dev/null | shuf -z)

if [[ ${#clusters[@]} -gt 0 ]]; then
	for workdir in "${clusters[@]}"; do
		queue deprovision "${workdir}"
	done
	wait
fi

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

FAILED=""
if [[ ${#clusters[@]} -gt 0 ]]; then
	FAILED="$(find "${clusters[@]}" -name failure -printf '%H\n' | sort)"
fi
final_rc=0

if [[ -n "${FAILED}" ]]; then
	echo "Deprovision failed on the following clusters:"
	xargs --max-args 1 basename <<< "$FAILED"
	final_rc=1
fi

if [[ "${inventory_failed}" -ne 0 ]]; then
	echo "LB inventory collection had failures."
	final_rc=1
fi

if [[ "${lb_cleanup_failed}" -ne 0 ]]; then
	echo "Load balancer cleanup had failures; some destroys were deferred."
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
