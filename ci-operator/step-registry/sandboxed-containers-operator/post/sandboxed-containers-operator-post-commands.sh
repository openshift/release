#!/bin/bash
#
# Attempt to delete extra cloud resources

# Avoid exiting on failure
set +e

# Safely removes kata config, if exists
cleanup_kata() {
	if oc get kataconfig -o yaml &>/dev/null; then
		if oc get kataconfig -o jsonpath='{.items[?(@.spec.enablePeerPods==true)].metadata.name}' 2>/dev/null | grep .; then
			# PeerPods enabled, delete the kataconfig
			if ! oc delete kataconfig --all --wait; then
				echo "Failed to delete kata-config, resources might be left-behind"
				exit 1
			fi
			echo "All kata configs deleted"
		else
			echo "PeerPods not enabled in kata-config, skipping kataconfig deletion as no external resources should be defined..."
		fi
	else
		echo "No kata configs found"
	fi
	exit 0
}

# Security groups created by the operator contain cross-references and can not
# be deleted by "openshift-install destroy". Prune the rules and leave them
# present.
prune_aws_security_groups() {
	local aws_region="$1"
	local infra_id sg_ids sg_id

	# Get infrastructure name (used in resource tags)
	infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null) || true
	if [[ -z "${infra_id}" ]]; then
		echo "Could not get infrastructure name, skipping security group cleanup"
		return 0
	fi

	echo "Cleaning up security groups for cluster ${infra_id} in region ${aws_region}..."

	# Find security groups tagged with the cluster's infrastructure name
	sg_ids=$(aws ec2 describe-security-groups \
		--region "${aws_region}" \
		--filters "Name=tag-key,Values=kubernetes.io/cluster/${infra_id}" \
		--query 'SecurityGroups[*].GroupId' \
		--output text 2>/dev/null) || true

	if [[ -z "${sg_ids}" ]]; then
		echo "No tagged security groups found for cluster ${infra_id}"
		return 0
	fi

	echo "Found security groups: ${sg_ids}"

	# Revoke all ingress and egress rules to remove cross-references
	for sg_id in ${sg_ids}; do
		echo "Revoking rules from security group ${sg_id}..."

		# Get and revoke all ingress rules
		local ingress_rules
		ingress_rules=$(aws ec2 describe-security-groups \
			--region "${aws_region}" \
			--group-ids "${sg_id}" \
			--query 'SecurityGroups[0].IpPermissions' \
			--output json 2>/dev/null) || true

		if [[ -n "${ingress_rules}" && "${ingress_rules}" != "[]" && "${ingress_rules}" != "null" ]]; then
			aws ec2 revoke-security-group-ingress \
				--region "${aws_region}" \
				--group-id "${sg_id}" \
				--ip-permissions "${ingress_rules}" 2>/dev/null || echo "Note: Could not revoke some ingress rules from ${sg_id}"
		fi

		# Get and revoke all egress rules
		local egress_rules
		egress_rules=$(aws ec2 describe-security-groups \
			--region "${aws_region}" \
			--group-ids "${sg_id}" \
			--query 'SecurityGroups[0].IpPermissionsEgress' \
			--output json 2>/dev/null) || true

		if [[ -n "${egress_rules}" && "${egress_rules}" != "[]" && "${egress_rules}" != "null" ]]; then
			aws ec2 revoke-security-group-egress \
				--region "${aws_region}" \
				--group-id "${sg_id}" \
				--ip-permissions "${egress_rules}" 2>/dev/null || echo "Note: Could not revoke some egress rules from ${sg_id}"
		fi
	done

	echo "Security group rules revoked, cross-references removed"
}

# Cleanup persistent AWS resources
# * AMI/snapshot (on failure just delete kata-config)
# * prune aws security groups (they contain cross-references and can not be removed otherwised)
cleanup_aws() {
	local ami_id aws_region aws_creds cm_data snapshot_id

	# Get aws credentials from secrets
	aws_creds=$(oc -n kube-system get secret aws-creds -o json)
	AWS_ACCESS_KEY_ID="$(echo "${aws_creds}" | jq -r .data.aws_access_key_id | base64 -d)"
	export AWS_ACCESS_KEY_ID
	AWS_SECRET_ACCESS_KEY="$(echo "${aws_creds}" | jq -r .data.aws_secret_access_key | base64 -d)"
	export AWS_SECRET_ACCESS_KEY

	# Check if cm exists
	if ! oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm -o yaml; then
		echo
		echo '"oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm" failed, fallback to kata deletion'
		cleanup_kata
	fi

	cm_data=$(oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm -o jsonpath='{.data}')
	ami_id=$(echo "${cm_data}" | jq -r '.PODVM_AMI_ID')
	aws_region=$(echo "${cm_data}" | jq -r '.AWS_REGION')

	if [[ -z "${aws_region}" ]]; then
		echo
		echo "No AWS_REGION in cm/peer-pods-cm, fallback to kata-cleanup"
		cleanup_kata
	fi

	# Clean up security group cross-references
	prune_aws_security_groups "${aws_region}"

	# Delete AMI/snapshot if possible
	if [[ -z "${ami_id}" ]]; then
		echo
		echo "No ami_id in cm/peer-pods-cm:"
		oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm -o yaml
		echo
		echo "Running kata-cleanup as fallback..."
		cleanup_kata
	fi

	# Describe image to get snapshot ID
	snapshot_id=$(aws ec2 describe-images --image-ids "${ami_id}" --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --region "${aws_region}" --output text)

	if [[ -z "${snapshot_id}" ]]; then
		echo
		echo "No snapshot found for AMI ${ami_id}, running kata-cleanup as fallback..."
		cleanup_kata
	fi

	# Deregister AMI
	if ! aws ec2 deregister-image --image-id "${ami_id}" --region "${aws_region}"; then
		echo
		echo "Failed to deregister image ${ami_id}, running kata-cleanup as fallback..."
		cleanup_kata
	fi
	echo "Deleted AMI: ${ami_id}"

	# Delete snapshot
	if ! aws ec2 delete-snapshot --snapshot-id "${snapshot_id}" --region "${aws_region}"; then
		echo
		echo "Failed to delete snapshot ${snapshot_id}, running kata-cleanup as fallback..."
		cleanup_kata
	fi
	echo "Deleted snapshot: ${snapshot_id}"

	echo "Skipping kata-cleanup as the default resources were removed manually"
	exit 0
}

# Remove our NSG on ARO+peer-pods (do nothing on plain azure)
cleanup_azure() {
	local IS_ARO
	IS_ARO=$(oc get crd clusters.aro.openshift.io &>/dev/null && echo true || echo false)
	if [[ "${IS_ARO}" != "true" ]]; then
		echo "We are not on ARO"
		return
	fi
	if [[ "${ENABLEPEERPODS:-false}" != "true" ]]; then
		echo "Peer-pods not enabled"
		return
	fi

	AZURE_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
	AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
	AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
	AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
	AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
	az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

	# delete kataconfig (to prevent starting new podvms)
	oc delete kataconfigs.kataconfiguration.openshift.io --all --wait=false || echo "::warning:: Failed to delete kata-config"

	# Delete potentially left-behind VMs
	az vm list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[?starts_with(name, 'podvm-')].name" --output tsv | xargs -I {} az vm delete --resource-group "${AZURE_RESOURCE_GROUP}" --name {} --yes --force-deletion 1 --no-wait
	echo "Deletion initiated. Waiting up to 60 seconds for all VMs to be removed..."
	SECONDS=0
	while [[ "${SECONDS}" -lt 60 ]] && az vm list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[?starts_with(name, 'podvm-')].name" --output tsv | grep -q .; do
		sleep 5
	done
	[[ "${SECONDS}" -ge 60 ]] && echo "::error:: Failed to delete all vms in 60s" && az vm list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[?starts_with(name, 'podvm-')].name" --output tsv
	echo "All is cleared"
}

# First check if PODVM_IMAGE was provided or generated
if [[ "${PODVM_IMAGE_URL}" ]]; then
  echo "Skipping cleanup, custom PODVM_IMAGE_URL=${PODVM_IMAGE_URL} specified"
  exit 0
fi

# Run per-provider cleanup
provider="$(oc get infrastructure -n cluster -o json | jq '.items[].status.platformStatus.type'  | awk '{print tolower($0)}' | tr -d '"')"

case ${provider} in
	aws)
		cleanup_aws ;;
	azure)
		cleanup_azure ;;
	*)
		echo "No post defined for provider ${provider}, skipping cleanup"
		exit 0;;
esac
