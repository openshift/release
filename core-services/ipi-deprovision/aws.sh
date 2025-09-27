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

function retry() {
    local retries=5
    local wait=5
    local n=0
    until "$@"; do
        n=$((n+1))
        if [[ $n -ge $retries ]]; then
            echo "Command failed after $n attempts: $*" >&2
            return 1
        fi
        echo "Retry $n/$retries for: $*" >&2
        sleep $((wait**n))
    done
}

function parse_arn_service() {
    local arn="$1"
    echo "$arn" | cut -d':' -f3
}

function parse_arn_resource_type() {
    local arn="$1"
    local service=$(parse_arn_service "$arn")
    local resource_part=$(echo "$arn" | cut -d':' -f6)
    
    case "$service" in
        "ec2")
            echo "$resource_part" | cut -d'/' -f1
            ;;
        "route53")
            echo "$resource_part" | cut -d'/' -f1
            ;;
        "iam")
            echo "$resource_part" | cut -d'/' -f1
            ;;
        "elasticloadbalancing")
            echo "$resource_part" | cut -d'/' -f1
            ;;
        "s3")
            echo "bucket"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

function parse_arn_resource_id() {
    local arn="$1"
    local service=$(parse_arn_service "$arn")
    local resource_part=$(echo "$arn" | cut -d':' -f6)
    
    case "$service" in
        "ec2"|"route53"|"iam"|"elasticloadbalancing")
            echo "$resource_part" | cut -d'/' -f2-
            ;;
        "s3")
            echo "$resource_part"
            ;;
        *)
            echo "$resource_part"
            ;;
    esac
}

function delete_ec2_resource() {
    local region="$1"
    local resource_type="$2"
    local resource_id="$3"
    
    case "$resource_type" in
        "instance")
            echo "Terminating EC2 instance: $resource_id"
            retry aws ec2 terminate-instances --region "$region" --instance-ids "$resource_id" || true
            ;;
        "volume")
            echo "Deleting EBS volume: $resource_id"
            retry aws ec2 delete-volume --region "$region" --volume-id "$resource_id" || true
            ;;
        "snapshot")
            echo "Deleting EBS snapshot: $resource_id"
            retry aws ec2 delete-snapshot --region "$region" --snapshot-id "$resource_id" || true
            ;;
        "security-group")
            echo "Deleting security group: $resource_id"
            retry aws ec2 delete-security-group --region "$region" --group-id "$resource_id" || true
            ;;
        "subnet")
            echo "Deleting subnet: $resource_id"
            retry aws ec2 delete-subnet --region "$region" --subnet-id "$resource_id" || true
            ;;
        "route-table")
            echo "Deleting route table: $resource_id"
            retry aws ec2 delete-route-table --region "$region" --route-table-id "$resource_id" || true
            ;;
        "internet-gateway")
            echo "Deleting internet gateway: $resource_id"
            # First detach from VPC if attached
            local vpcs=$(aws ec2 describe-internet-gateways --region "$region" --internet-gateway-ids "$resource_id" --query 'InternetGateways[].Attachments[].VpcId' --output text || true)
            for vpc in $vpcs; do
                retry aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$resource_id" --vpc-id "$vpc" || true
            done
            retry aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$resource_id" || true
            ;;
        "natgateway")
            echo "Deleting NAT gateway: $resource_id"
            retry aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$resource_id" || true
            ;;
        "vpc")
            echo "Deleting VPC: $resource_id"
            retry aws ec2 delete-vpc --region "$region" --vpc-id "$resource_id" || true
            ;;
        "network-interface")
            echo "Deleting network interface: $resource_id"
            retry aws ec2 delete-network-interface --region "$region" --network-interface-id "$resource_id" || true
            ;;
        *)
            echo "Unknown EC2 resource type: $resource_type ($resource_id)"
            ;;
    esac
}

function delete_elb_resource() {
    local region="$1"
    local resource_type="$2"
    local resource_id="$3"
    
    case "$resource_type" in
        "loadbalancer")
            if [[ "$resource_id" == app/* ]] || [[ "$resource_id" == net/* ]]; then
                echo "Deleting ALB/NLB: $resource_id"
                retry aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn "arn:aws:elasticloadbalancing:$region:*:loadbalancer/$resource_id" || true
            else
                echo "Deleting classic ELB: $resource_id"
                retry aws elb delete-load-balancer --region "$region" --load-balancer-name "$resource_id" || true
            fi
            ;;
        "targetgroup")
            echo "Deleting target group: $resource_id"
            retry aws elbv2 delete-target-group --region "$region" --target-group-arn "arn:aws:elasticloadbalancing:$region:*:targetgroup/$resource_id" || true
            ;;
        *)
            echo "Unknown ELB resource type: $resource_type ($resource_id)"
            ;;
    esac
}

function delete_iam_resource() {
    local resource_type="$1"
    local resource_id="$2"
    
    case "$resource_type" in
        "role")
            echo "Deleting IAM role: $resource_id"
            # Detach managed policies
            aws iam list-attached-role-policies --role-name "$resource_id" --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | while read -r policy; do
                [[ -n "$policy" ]] && retry aws iam detach-role-policy --role-name "$resource_id" --policy-arn "$policy" || true
            done
            # Delete inline policies
            aws iam list-role-policies --role-name "$resource_id" --query 'PolicyNames[]' --output text | tr '\t' '\n' | while read -r policy; do
                [[ -n "$policy" ]] && retry aws iam delete-role-policy --role-name "$resource_id" --policy-name "$policy" || true
            done
            # Delete instance profiles
            aws iam list-instance-profiles-for-role --role-name "$resource_id" --query 'InstanceProfiles[].InstanceProfileName' --output text | tr '\t' '\n' | while read -r profile; do
                [[ -n "$profile" ]] && retry aws iam remove-role-from-instance-profile --role-name "$resource_id" --instance-profile-name "$profile" || true
            done
            retry aws iam delete-role --role-name "$resource_id" || true
            ;;
        "instance-profile")
            echo "Deleting IAM instance profile: $resource_id"
            # Remove roles from instance profile first
            aws iam get-instance-profile --instance-profile-name "$resource_id" --query 'InstanceProfile.Roles[].RoleName' --output text | tr '\t' '\n' | while read -r role; do
                [[ -n "$role" ]] && retry aws iam remove-role-from-instance-profile --role-name "$role" --instance-profile-name "$resource_id" || true
            done
            retry aws iam delete-instance-profile --instance-profile-name "$resource_id" || true
            ;;
        "policy")
            echo "Deleting IAM policy: $resource_id"
            retry aws iam delete-policy --policy-arn "arn:aws:iam::*:policy/$resource_id" || true
            ;;
        *)
            echo "Unknown IAM resource type: $resource_type ($resource_id)"
            ;;
    esac
}

function delete_route53_resource() {
    local resource_type="$1"
    local resource_id="$2"
    
    case "$resource_type" in
        "hostedzone")
            echo "Deleting Route53 hosted zone: $resource_id"
            # Delete all records except NS and SOA first
            local records=$(aws route53 list-resource-record-sets --hosted-zone-id "$resource_id" --query "ResourceRecordSets[?Type != 'NS' && Type != 'SOA']" --output json || true)
            for record in $(echo "$records" | jq -r '.[] | @base64'); do
                local rname=$(echo "$record" | base64 --decode | jq -r .Name)
                local rtype=$(echo "$record" | base64 --decode | jq -r .Type)
                echo "  Deleting Route53 record: $rname ($rtype)"
                aws route53 change-resource-record-sets \
                    --hosted-zone-id "$resource_id" \
                    --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$(echo "$record" | base64 --decode)}]}" || true
            done
            retry aws route53 delete-hosted-zone --id "$resource_id" || true
            ;;
        *)
            echo "Unknown Route53 resource type: $resource_type ($resource_id)"
            ;;
    esac
}

function delete_s3_resource() {
    local resource_id="$1"
    
    echo "Deleting S3 bucket: $resource_id"
    # First empty the bucket
    aws s3 rm "s3://$resource_id" --recursive || true
    # Delete all versions and delete markers
    aws s3api list-object-versions --bucket "$resource_id" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text | while read -r key version; do
        [[ -n "$key" && -n "$version" ]] && aws s3api delete-object --bucket "$resource_id" --key "$key" --version-id "$version" || true
    done
    aws s3api list-object-versions --bucket "$resource_id" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text | while read -r key version; do
        [[ -n "$key" && -n "$version" ]] && aws s3api delete-object --bucket "$resource_id" --key "$key" --version-id "$version" || true
    done
    retry aws s3api delete-bucket --bucket "$resource_id" || true
}

function comprehensive_cleanup_by_tags() {
    local region="$1"
    local cluster="$2"
    
    echo "Starting cleanup for cluster $cluster in region $region"
    
    # Get all resources tagged with the cluster
    local resources_json="/tmp/cluster-resources-${cluster}-${region}.json"
    aws resourcegroupstaggingapi get-resources \
        --region "$region" \
        --tag-filters "Key=kubernetes.io/cluster/${cluster},Values=owned" \
        --output json > "$resources_json" || true
    
    if [[ ! -s "$resources_json" ]]; then
        echo "No tagged resources found for cluster $cluster in region $region"
        return 0
    fi
    
    echo "Found tagged resources for cluster $cluster:"
    jq -r '.ResourceTagMappingList[].ResourceARN' "$resources_json" | sort
    
    # Parse resources by service and type
    declare -A ec2_resources elb_resources iam_resources s3_resources route53_resources other_resources
    
    while IFS= read -r arn; do
        [[ -z "$arn" ]] && continue
        
        local service=$(parse_arn_service "$arn")
        local resource_type=$(parse_arn_resource_type "$arn")
        local resource_id=$(parse_arn_resource_id "$arn")
        
        case "$service" in
            "ec2")
                ec2_resources["$resource_type"]+="$resource_id "
                ;;
            "elasticloadbalancing")
                elb_resources["$resource_type"]+="$resource_id "
                ;;
            "iam")
                iam_resources["$resource_type"]+="$resource_id "
                ;;
            "s3")
                s3_resources["bucket"]+="$resource_id "
                ;;
            "route53")
                route53_resources["$resource_type"]+="$resource_id "
                ;;
            *)
                other_resources["$service"]+="$arn "
                ;;
        esac
    done < <(jq -r '.ResourceTagMappingList[].ResourceARN' "$resources_json")
    
    # Delete resources in proper dependency order
    
    # 1. Delete EC2 instances first (to release network interfaces, etc.)
    if [[ -n "${ec2_resources[instance]:-}" ]]; then
        for instance_id in ${ec2_resources[instance]}; do
            delete_ec2_resource "$region" "instance" "$instance_id"
        done
        # Wait for instances to terminate
        echo "Waiting for instances to terminate..."
        sleep 30
    fi
    
    # 2. Delete load balancers (they use target groups and security groups)
    for resource_type in "${!elb_resources[@]}"; do
        for resource_id in ${elb_resources[$resource_type]}; do
            delete_elb_resource "$region" "$resource_type" "$resource_id"
        done
    done
    
    # Wait for ELBs to be deleted
    echo "Waiting for load balancers to be deleted..."
    sleep 30
    
    # 3. Delete other EC2 resources (order matters)
    local ec2_deletion_order=("network-interface" "natgateway" "internet-gateway" "route-table" "subnet" "security-group" "volume" "snapshot" "vpc")
    for resource_type in "${ec2_deletion_order[@]}"; do
        if [[ -n "${ec2_resources[$resource_type]:-}" ]]; then
            for resource_id in ${ec2_resources[$resource_type]}; do
                delete_ec2_resource "$region" "$resource_type" "$resource_id"
            done
        fi
    done
    
    # 4. Delete S3 buckets
    for resource_id in ${s3_resources[bucket]:-}; do
        delete_s3_resource "$resource_id"
    done
    
    # 5. Delete IAM resources
    for resource_type in "${!iam_resources[@]}"; do
        for resource_id in ${iam_resources[$resource_type]}; do
            delete_iam_resource "$resource_type" "$resource_id"
        done
    done
    
    # 6. Delete tagged Route53 resources (hosted zones)
    for resource_type in "${!route53_resources[@]}"; do
        for resource_id in ${route53_resources[$resource_type]}; do
            delete_route53_resource "$resource_type" "$resource_id"
        done
    done
    
    # 7. Clean up untagged Route53 records (domain pattern matching)
    # Note: Route53 records are typically not tagged, so we use domain pattern matching
    # to catch any records in hosted zones that match the cluster domain pattern
    cleanup_route53_by_domain "$cluster"
    
    # 8. Log any unhandled resources
    for service in "${!other_resources[@]}"; do
        echo "WARNING: Unhandled resources for service $service:"
        for arn in ${other_resources[$service]}; do
            echo "  $arn"
        done
    done
    
    # Clean up temporary file
    rm -f "$resources_json"
    
    echo "Cleanup completed for cluster $cluster in region $region"
}

function cleanup_route53_by_domain() {
    local cluster="$1"

    zones=$(aws route53 list-hosted-zones --query "HostedZones[?Name == '${cluster}.${HYPERSHIFT_BASE_DOMAIN}.'].Id" --output text || true)
    for zone in $zones; do
        records=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --query "ResourceRecordSets[?Type != 'NS' && Type != 'SOA']" --output json || true)
        for record in $(echo "$records" | jq -r '.[] | @base64'); do
            rname=$(echo "$record" | base64 --decode | jq -r .Name)
            rtype=$(echo "$record" | base64 --decode | jq -r .Type)
            aws route53 change-resource-record-sets \
                --hosted-zone-id "$zone" \
                --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$(echo "$record" | base64 --decode)}]}" || true
        done
        retry aws route53 delete-hosted-zone --id "$zone" || true
    done
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

	# Failsafe: if cluster destroy failed, use tagged resource cleanup
    if [[ -f "${WORKDIR}/failure" ]]; then
        cluster="${WORKDIR##*/}"
        echo "Using tagged resource cleanup with Resource Groups Tagging API"
        comprehensive_cleanup_by_tags "${REGION}" "${cluster}"
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
		aws iam get-groups-for-user --user-name "$user" --query 'Groups[].GroupName' --output text | tr '\t' '\n' | while read -r group; do
			[[ -n "$group" ]] && aws iam remove-user-from-group --user-name "$user" --group-name "$group" || true
		done
		aws iam delete-user --user-name "$user" && echo "✓ Deleted: $user"
	fi
done

FAILED="$(find ${clusters} -name failure -printf '%H\n' | sort)"
if [[ -n "${FAILED}" ]]; then
	echo "Deprovision failed on the following clusters:"
	xargs --max-args 1 basename <<< $FAILED
	exit 1
fi

echo "Deprovision finished successfully"
