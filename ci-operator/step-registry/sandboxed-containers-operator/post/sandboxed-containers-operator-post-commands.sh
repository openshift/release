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

# Delete AMI/snapshot if not provided manually, fall-backs to
# kata-config cleanup if something goes wrong
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

	# Get peer-pods-cm once, extract PODVM_AMI_ID and AWS_REGION
	cm_data=$(oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm -o jsonpath='{.data}')
	ami_id=$(echo "${cm_data}" | jq -r '.PODVM_AMI_ID')
	aws_region=$(echo "${cm_data}" | jq -r '.AWS_REGION')

	if [[ -z "${aws_region}" ]]; then
		echo
		echo "No AWS_REGION in cm/peer-pods-cm, fallback to kata-cleanup"
		cleanup_kata
	fi

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
	*)
		echo "No post defined for provider ${provider}, skipping cleanup"
		exit 0;;
esac
