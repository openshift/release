#!/bin/bash
#
# Attempt to delete extra cloud resources


# Safely removes kata config, if exists
cleanup_kata() {
	if oc get kataconfigurations.kataconfiguration.openshift.io &>/dev/null; then
		if ! oc delete kataconfigurations.kataconfiguration.openshift.io --all --wait; then
			echo "Failed to delete kata-config, resources might be left-behind"
			exit 1
		fi
		echo "All kata configs deleted"
	else
		echo "No kata configs found"
	fi
	exit 0
}

# Delete AMI/snapshot if not provided manually, fall-backs to
# kata-config cleanup if something goes wrong
cleanup_aws() {
	local ami_id
	ami_id="$(oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm -o jsonpath='{.data.PODVM_AMI_ID}')"
	if [[ -z "${ami_id}" ]]; then
		echo "No ami_id in cm/peer-pods-cm:"
		oc get -n openshift-sandboxed-containers-operator cm/peer-pods-cm -o yaml
		echo
		echo "Running kata-cleanup as fallback..."
		cleanup_kata
	fi
	local snapshot_id
	snapshot_id="$(aws ec2 describe-images --image-ids "${ami_id}" --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)"
	if [[ -z "${snapshot_id}" ]]; then
		echo "No snapshot found for AMI ${ami_id}, running kata-cleanup as fallback..."
		cleanup_kata
	fi

	if ! aws ec2 deregister-image --image-id "${ami_id}"; then
		echo "Failed to deregister image ${ami_id}, running kata-cleanup as fallback..."
		cleanup_kata
	fi
	echo "Deleted AMI: ${ami_id}"
	if ! aws ec2 delete-snapshot --snapshot-id "${snapshot_id}"; then
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
