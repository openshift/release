#!/bin/bash

set -o nounset
set +o errexit
set -o pipefail

workdir=`mktemp -d`

#Download butane
curl -sSL "https://mirror2.openshift.com/pub/openshift-v4/clients/butane/latest/butane" --output /tmp/butane && chmod +x /tmp/butane

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST,
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with
# user specified image pullspec, to avoid auth error when accessing it, always use build farm
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
butane_version_list=("${ocp_version}.0" "$(echo ${ocp_version} | awk -F. -v OFS=. '{$NF -= 1 ; print}').0")
echo "butane_version_list:" "${butane_version_list[@]}"

roles="master worker"
if [[ "${DISK_PARTITION_DIR}" == "var" ]]; then
    path="/var"
elif [[ "${DISK_PARTITION_DIR}" == "var_container" ]]; then
    path="/var/lib/containers"
elif [[ "${DISK_PARTITION_DIR}" == "var_etcd" ]]; then
    roles="master"
    path="/var/lib/etcd"
else
    echo "ERROR: unsupported DISK_PARTITION_DIR, valid value: var var_container var_etcd!"
    exit 1
fi

ret=0
for butane_version in "${butane_version_list[@]}"; do
    for role in ${roles}; do
        ret=0
        bu_file_name="98-${DISK_PARTITION_DIR}-partition-${role}.bu"
        manifest_file_name="manifest_${DISK_PARTITION_DIR}-partition-${role}.yml"
        cat > "${workdir}/${bu_file_name}" << EOF
variant: openshift
version: ${butane_version}
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: 98-var-partition-${role}
storage:
  disks:
  - device: /dev/disk/azure/scsi1/lun0
    partitions:
    - label: data01
      start_mib: 0
      size_mib: 0
  filesystems:
    - device: /dev/disk/by-partlabel/data01
      path: ${path}
      format: xfs
      mount_options: [defaults, prjquota] 
      with_mount_unit: true
EOF
        /tmp/butane "${workdir}/${bu_file_name}" > "${workdir}/${manifest_file_name}" || ret=1
        if [[ ${ret} -eq 1 ]]; then
            echo "Butane failed to transform '${bu_file_name}' to machineconfig file using version '${butane_version}' (non-GA?)."
            break
        fi

        cp -f "${workdir}/${manifest_file_name}" "${SHARED_DIR}/${manifest_file_name}"
        cp -f "${workdir}/${manifest_file_name}" "${ARTIFACT_DIR}/${manifest_file_name}"
    done

    if [[ ${ret} -eq 0 ]]; then
        echo "Succeed to transform ${DISK_PARTITION_DIR} partition BU file to machineconfig file using version '${butane_version}'"
        break
    fi
done

# abort if all versions from the array have failed
if [[ ${ret} -ne 0 ]]; then
  echo "Butane failed to transform storage templates into machineconfig files. Aborting execution."
  exit 1
fi

#need to update arm template to create additional disk
for role in ${roles}; do
    cat > "${SHARED_DIR}/azure_arm_template_new_disk_${role}" << EOF
{"type": "int","defaultValue": 30,"metadata": {"description": "Size of the Master VM 2nd data disk, in GB"}}
{"dataDisks": [{"diskSizeGB": "[parameters('additionalDiskSizeGB')]","lun": 0,"createOption": "Empty"}]}
EOF
    azure_disk_size="AZURE_${role^^}_NEW_DISK_SIZE"
    cat > "${SHARED_DIR}/azure_${role}_new_disk_info" << EOF
{"path": "${path}","disk_size": ${!azure_disk_size}}
EOF
done
