#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Credentials come from ci-operator's STS setup for the test's cluster_profile:
# a projected web-identity token is exchanged through the per-cluster -> hub ->
# per-account role chain that ci-operator writes to
# /var/run/secrets/aws/config/config. Running under a cluster_profile means this
# pod executes as a trusted ci-op-* identity (which the ci-step-runner roles
# trust), unlike a raw pod in the "ci" namespace.
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE="/var/run/secrets/aws/config/config"

function finish {
	CHILDREN=$(jobs -p)
	if test -n "${CHILDREN}"; then
		kill ${CHILDREN} && wait
	fi
	exit # since bash doesn't handle SIGQUIT, we need an explicit "exit"
}
trap finish TERM QUIT

function queue() {
	local LIVE
	LIVE="$(jobs | wc -l)"
	while [[ "${LIVE}" -ge 2 ]]; do
		sleep 1
		LIVE="$(jobs | wc -l)"
	done
	echo "${@}"
	"${@}" &
}

function deprovision() {
	local WORKDIR="${1}"
	timeout --signal=SIGTERM 60m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
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

logdir="${ARTIFACT_DIR}/deprovision"
mkdir -p "${logdir}"
inventory_dir="$(mktemp -d)"

aws_cluster_age_cutoff="$(TZ=":Africa/Abidjan" date --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M+0000')"
echo "deprovisioning clusters with an expirationDate before ${aws_cluster_age_cutoff} in AWS ..."

# Phase 1: collect LB inventories for every region. Failures must not become empty lists.
mapfile -t regions < <(aws ec2 describe-regions --region us-east-1 --query "Regions[].{Name:RegionName}" --output text | tr '\t' '\n')
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

if [[ ${final_rc} -ne 0 ]]; then
	exit 1
fi

echo "Deprovision finished successfully"
