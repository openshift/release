#!/bin/bash

#
# Multi-region manifest validation for edge zones
#
# Steps:
# discover regions
# discover edge-zones (WL and LZ) in the region
# test add single-zone for LZ (and && or) WL in the IC
# test add full-zones for LZ and WL in IC
# for each test, validate the manifests:
# - render manifests must pass
# - instance type for capi zone manifest must not be empty
# - edge labels exists
#
# Local run: CLUSTER_PROFILE_DIR=$HOME/tmp ARTIFACT_DIR=/tmp/ci bash -x ci-operator/step-registry/openshift/installer/manifests/aws/edge-zones/openshift-installer-manifests-aws-edge-zones-commands.sh
#

set -o nounset
set -o errexit
set -o pipefail

declare -x INSTALLER_BIN
INSTALLER_BIN="$(which openshift-install)"

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export INSTALL_CONFIG_BASE="${SHARED_DIR}"/install-config.yaml
export FILE_ALL_REGIONS="${ARTIFACT_DIR}"/regions_all.json

JUNIT_TEST_SUITE="installer-manifest-check-edge-zones"
JUNIT_TEST_COUNT=0
JUNIT_TEST_SKIPPED=0
JUNIT_TEST_FAILURES=0
JUNIT_BUFFER_FILE_CASES=/tmp/test-cases.xml
JUNIT_BUFFER_FILE_MSG=/tmp/test-case-buffer.txt

function finalizer() {
    cat >"${ARTIFACT_DIR}/junit_checks.xml" <<EOF
    <testsuite name="$JUNIT_TEST_SUITE" tests="$JUNIT_TEST_COUNT" failures="$JUNIT_TEST_FAILURES" skipped="${JUNIT_TEST_SKIPPED}">
      $(cat $JUNIT_BUFFER_FILE_CASES || true)
    </testsuite>
EOF

    exit $JUNIT_TEST_FAILURES
}
trap finalizer EXIT

function add_test_case() {
    local test_name="[sig-install] $1"; shift
    local test_time="$1"; shift
    local test_result="$1"; # pass|failed|skipped

    JUNIT_TEST_COUNT=$(( JUNIT_TEST_COUNT + 1 ))

    case $test_result in
    "pass")
        cat >>"${JUNIT_BUFFER_FILE_CASES}" <<EOF
      <testcase name="${test_name}" time="${test_time}">
      <system-out>
        $(cat "${JUNIT_BUFFER_FILE_MSG}" || true)
      </system-out>
      </testcase>
EOF
    ;;
    "failed")
        JUNIT_TEST_FAILURES=$(( JUNIT_TEST_FAILURES + 1 ))
        cat >>"${JUNIT_BUFFER_FILE_CASES}" <<EOF
        <testcase name="${test_name}">
            <failure message="">
            $(cat "${JUNIT_BUFFER_FILE_MSG}" || true)
            </failure>
        </testcase>
EOF
    ;;
    "skipped")
        JUNIT_TEST_SKIPPED=$(( JUNIT_TEST_SKIPPED + 1 ))
        cat >>"${JUNIT_BUFFER_FILE_CASES}" <<EOF
        <testcase name="${test_name}">
            <skipped message="$(cat ${JUNIT_BUFFER_FILE_MSG} || true)" />
        </testcase>
EOF
    ;;
    *) echo_date "Unable to find test result [$test_result]" ;;
    esac
}

# echo prints a message with timestamp.
function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

# opt_in_zone_group is a helper function to enable the zone group from a given region.
function opt_in_zone_group() {
    local region_name=$1; shift
    local zone_type=$1; shift
    local zone_name=$1; shift
    local zone_group_name=$1

    aws --region "${region_name}" ec2 modify-availability-zone-group --group-name "${zone_group_name}" --opt-in-status opted-in
    echo_date "Zone group ${zone_group_name} opt-in status modified"

    count=0
    while true; do
        aws --region "${region_name}" ec2 describe-availability-zones --all-availability-zones \
            --filters Name=zone-type,Values="${zone_type}" Name=zone-name,Values="${zone_name}" \
            | jq -r '.AvailabilityZones[]' | tee /tmp/az.stat

        if [[ "$(jq -r .OptInStatus /tmp/az.stat)" == "opted-in" ]]; then break; fi

        if [ $count -ge 10 ]; then
            echo_date "Timeout waiting for zone ${zone_name} attribute OptInStatus==opted-in"
            echo "${zone_name}" >>"${ARTIFACT_DIR}/edge-zones-disabled_${region_name}_failed-to-enable.txt"
            break
        fi

        count=$((count+1))
        echo_date "Waiting OptInStatus with value opted-in [${count}/10]"
        sleep 30
    done

    echo_date "Zone group ${zone_group_name} opted-in."
    # Final wait is required to prevent inconsistency in AWS API when generating assets.
    sleep 15
}

function enable_zones() {
    local region=$1; shift

    while read -r zone_name; do
        local zone_type
        zone_type=$(jq -r ".AvailabilityZones[] | select(.ZoneName==\"${zone_name}\").ZoneType" "${ARTIFACT_DIR}/edge-zones_${region}.json")
        local zone_group
        zone_group=$(jq -r ".AvailabilityZones[] | select(.ZoneName==\"${zone_name}\").GroupName" "${ARTIFACT_DIR}/edge-zones_${region}.json")

        echo_date "Trying to enable zone group ${zone_group} (${zone_type})"
        opt_in_zone_group "${region_name}" "${zone_type}" "${zone_name}" "${zone_group}"
    done <<< "$(cat "${ARTIFACT_DIR}/edge-zones-disabled_${region_name}.txt")"
}

# aws_describe_regions describes all regions in the globe, including disabled, creating a json file with raw result.
function aws_describe_regions() {
    echo_date "Discovering regions"
    aws ec2 describe-regions --region "us-east-1" --all-regions > "${FILE_ALL_REGIONS}"
    echo -e "REGION\t\tSTATUS"
    jq -r ' .Regions[] | [.RegionName, .OptInStatus] | @tsv' "${FILE_ALL_REGIONS}"
}

# aws_describe_edge_zones describes all zones in the region, creating a json file with raw result.
function aws_describe_edge_zones() {
    local region=$1; shift
    local zones_filename="edge-zones_${region}.json"
    aws ec2 describe-availability-zones --region "$region" --all-availability-zones \
        --filter Name=zone-type,Values="local-zone,wavelength-zone" \
        > "/tmp/$zones_filename"

    if [[ $(jq -r '.AvailabilityZones | length' "/tmp/$zones_filename") -le 0 ]]; then
        echo "Region $region does not have valid edge zones. Ignoring...."
        return
    fi
    echo "$region" >> "${ARTIFACT_DIR}/regions_edge.txt"
    mv "/tmp/$zones_filename" "${ARTIFACT_DIR}/"
}

# get_enabled_edge_zones lookup disabled (opted-out) zones in the region, when exists creates a filed with disabled zones.
function get_enabled_edge_zones() {
    local region=$1; shift
    local zones_filename="edge-zones_${region}.json"
    local failed_zone_file="${ARTIFACT_DIR}/edge-zones-disabled_${region}.txt"
    local count_opted_out
    count_opted_out=$(jq -r '.AvailabilityZones[] | select(.OptInStatus=="not-opted-in").ZoneName' "${ARTIFACT_DIR}/$zones_filename" | wc -l)
    if [[ ${count_opted_out} -gt 0 ]]; then
        jq -r '.AvailabilityZones[] | select(.OptInStatus=="not-opted-in").ZoneName' "${ARTIFACT_DIR}/$zones_filename" > "$failed_zone_file"
    fi
}

# test_render_single_type selects randomly a zone within the region with a given zone type and validates manifests.
function test_render_single_type() {
    local test_name="render-single"
    local region=$1; shift
    local zone_type=$1
    local zone_name

    zone_name=$(jq -r ".AvailabilityZones[] | select(.ZoneType==\"$zone_type\").ZoneName" "${ARTIFACT_DIR}/edge-zones_${region}.json" | shuf |head -n1)
    local result_file="${ARTIFACT_DIR}/test_single_type-$zone_name.txt"

    if [[ "${zone_name}" == "" ]]; then
        echo "INFO: Unable to find zones with type ${zone_type} in the region ${region}, skipping test case..."
        return
    fi

    echo "#>>>>>
# [${region}] Running test: Render Single Type
- Zone Type: ${zone_type}
- Zone Name selected: ${zone_name}
- Result file: $result_file
#>>>>>"

    echo "$zone_name" > "$result_file"
    create_install_patch "$test_name" "$region" "$result_file"
    test_render_validations "$test_name" "$region" "$result_file"
}

# test_render_mixed_type selects randomly one zone by type within the region and validates manifests.
function test_render_mixed_type() {
    local test_name="render-mixed"
    local region=$1; shift
    local result_file="${ARTIFACT_DIR}/test_mixed_type-${region}.txt"

    echo "#>>>>>
# [$region] Running test: Render Mixed Type
- Result file: $result_file
#>>>>>"

    zone_type="local-zone"
    jq -r ".AvailabilityZones[] | select(.ZoneType==\"$zone_type\").ZoneName" "${ARTIFACT_DIR}/edge-zones_${region}.json" | shuf | head -n1 > "$result_file"

    zone_type="wavelength-zone"
    jq -r ".AvailabilityZones[] | select(.ZoneType==\"$zone_type\").ZoneName" "${ARTIFACT_DIR}/edge-zones_${region}.json" | shuf | head -n1 >> "$result_file"

    if [[ $(wc -l < "${result_file}") -eq 1 ]]; then
        echo "Skipping mixed test in region ${region} as it has only one edge zone type. 'test_render_all' will perform the required validations."
        return
    fi

    create_install_patch "$test_name" "$region" "$result_file"
    test_render_validations "$test_name" "$region" "$result_file"
}

# test_render_all_types selects all edge zones in region and validates manifests.
function test_render_all_types() {
    local test_name="render-all"
    local region=$1; shift
    local result_file="${ARTIFACT_DIR}/test_all_types-${region}.txt"

    jq -r ".AvailabilityZones[].ZoneName" "${ARTIFACT_DIR}/edge-zones_${region}.json" > "$result_file"

    echo "#>>>>>
# [$region] Running test: Render All Types
- Result file: $result_file
#>>>>>"

    create_install_patch "$test_name" "$region" "$result_file"
    test_render_validations "$test_name" "$region" "$result_file"
}

# patch install-config setting edge zones and region
function create_install_patch() {
    test_name=$1; shift
    region=$1; shift
    result_file=$1

    INSTALL_DIR=/tmp/install-dirs/$region-$test_name
    config=$INSTALL_DIR/install-config.yaml
    patch_file=$result_file.ic-patch.yaml

    mkdir -p "$INSTALL_DIR"
    cp "$INSTALL_CONFIG_BASE" "$config"

    zones_arr=$(tr '\n' ',' < "${result_file}" | sed 's/,$//')

    # Cleaning defaults from previous steps to force using custom region.
    cat << EOF > "${patch_file}"
metadata:
  name: $test_name
platform:
  aws:
    region: $region
controlPlane:
  platform:
    aws: {}
compute:
- name: worker
  platform:
    aws: {}
- name: edge
  platform:
    aws:
      zones: [ $zones_arr ]
EOF
    yq-go m -x -i "${config}" "${patch_file}"
    echo_date ">> Install Config:"
    grep -v "password\|username\|pullSecret\|{\"auths\":{\|sshKey\|ssh-" "$INSTALL_DIR/install-config.yaml" | tee "${result_file}.ic.yaml"
}

function test_render_validations() {
    test_name=$1; shift
    region=$1; shift
    result_file=$1
    INSTALL_DIR="/tmp/install-dirs/${region}-${test_name}"

    # render manifests
    # - check instance type has been filled
    # - check if labels has been applied
    # Failing due bug https://issues.redhat.com//browse/OCPBUGS-27737
    echo -e "${test_name}[${region}]>> Creating Manifests\n"
    $INSTALLER_BIN create manifests --dir "$INSTALL_DIR" || true

    test_item_name="${test_name} Region ${region} rendered one or more machine set manifests"
    test_result="pass"
    if ! ls "$INSTALL_DIR"/openshift/99_openshift-cluster-api_worker-machineset-*; then
        test_result="failed"
        err_msg="[${region}] Unable to find machine set manifests in the path: $INSTALL_DIR/openshift/99_openshift-cluster-api_worker-machineset-*."
        echo -e "${test_item_name}\n ${err_msg}." | tee -a "$JUNIT_BUFFER_FILE_MSG"
    fi
    add_test_case "${test_item_name}" "0" "${test_result}"

    # continue the execution across other regions when test case has failed to generate manifests.
    if [[ "${test_result}" == "failed" ]];
    then
        return
    fi

    test_mc_prefix="[${test_name}] machine set for"
    for mc in "$INSTALL_DIR"/openshift/99_openshift-cluster-api_worker-machineset-*;
    do
        yq-go r -j "${mc}" > "${mc}.json"
        name=$(yq-go r -j "${mc}" | jq -r '.metadata.name')
        role=$(yq-go r -j "${mc}" | jq -r '.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"]')
        instanceType=$(yq-go r -j "${mc}" | jq -r '.spec.template.spec.providerSpec.value.instanceType')
        zoneName=$(yq-go r -j "${mc}" | jq -r '.spec.template.spec.providerSpec.value.placement.availabilityZone')
        
        test_item_name="${test_mc_prefix} zone ${zoneName} has valid instanceType"
        test_result="pass"
        if [[ "${instanceType}" == "" ]]; then
            err_msg="ERROR [$mc] MachineSet $name has invalid instanceType. Rendered instance type=${instanceType}"
            echo -e "${test_item_name}\n ${err_msg}." | tee -a "$JUNIT_BUFFER_FILE_MSG"
           test_result="failed"
        fi
        add_test_case "${test_item_name}" "0" "${test_result}"

        # log instance types rendered by installer
        zoneType=$(jq -r ".AvailabilityZones[] | select(.ZoneName==\"${zoneName}\").ZoneType" "${ARTIFACT_DIR}/edge-zones_${region}.json")
        parentZone=$(jq -r ".AvailabilityZones[] | select(.ZoneName==\"${zoneName}\").ParentZoneName" "${ARTIFACT_DIR}/edge-zones_${region}.json")
        zoneGroup=$(jq -r ".AvailabilityZones[] | select(.ZoneName==\"${zoneName}\").GroupName" "${ARTIFACT_DIR}/edge-zones_${region}.json")

        if [[ -z "${zoneType}" ]]; then
            zoneType="availability-zone"
        fi
        if [[ -z "${zoneType}" ]]; then
            parentZone="N/A"
        fi
        echo "{\"zoneType\":\"${zoneType}\",\"zoneName\": \"${zoneName}\", \"parentZone\":\"${parentZone}\",\"instanceType\": \"$instanceType\"}" >> "${ARTIFACT_DIR}/all_zones-instanceTypes.json"

        # Proceed with checks only in edge Machine Set manifests.
        if [[ "${role}" != "edge" ]]; then
            continue
        fi

        test_item_name="${test_mc_prefix} zone ${zoneName}  has valid value for label machine.openshift.io/zone-type"
        test_result="pass"
        manifest_zoneType=$(yq-go r -j "${mc}" | jq -r '.spec.template.spec.metadata.labels["machine.openshift.io/zone-type"]')
        if [[ "${manifest_zoneType}" != "${zoneType}" ]]; then
            err_msg="[${region}][${zoneName}] The machine set manifest ${mc} has unexpected value for label machine.openshift.io/zone-type. ${manifest_zoneType} != ${zoneType}."
            echo -e "${test_item_name}\n ${err_msg}." | tee -a "$JUNIT_BUFFER_FILE_MSG"
           test_result="failed"
        fi
        add_test_case "${test_item_name}" "0" "${test_result}"

        test_item_name="${test_mc_prefix} zone ${zoneName} has valid value for label machine.openshift.io/zone-group"
        test_result="pass"
        manifest_zoneGroup=$(yq-go r -j "${mc}" | jq -r '.spec.template.spec.metadata.labels["machine.openshift.io/zone-group"]')
        if [[ "${manifest_zoneGroup}" != "${zoneGroup}" ]]; then
            err_msg="[${region}][${zoneName}] The machine set manifest ${mc} has unexpected value for label machine.openshift.io/zone-type. ${manifest_zoneGroup} != ${zoneGroup}."
            echo -e "${test_item_name}\n ${err_msg}." | tee -a "$JUNIT_BUFFER_FILE_MSG"
           test_result="failed"
        fi
        add_test_case "${test_item_name}" "0" "${test_result}"

        test_item_name="${test_mc_prefix} zone ${zoneName} has valid NoSchedule taints for label node-role.kubernetes.io/edge"
        test_result="pass"
        manifest_edge_taint_effect=$(yq-go r -j "${mc}" | jq -r '.spec.template.spec.taints[] | select(.key="node-role.kubernetes.io/edge").effect')
        if [[ "${manifest_edge_taint_effect}" != "NoSchedule" ]]; then
            err_msg="[${region}][${zoneName}] The machine set manifest ${mc} does not have the required taints to NoSchedule on nodes with label node-role.kubernetes.io/edge."
            echo -e "${test_item_name}\n ${err_msg}." | tee -a "$JUNIT_BUFFER_FILE_MSG"
           test_result="failed"
        fi
        add_test_case "${test_item_name}" "0" "${test_result}"
    done
}

#
# Main
#
aws_describe_regions
touch "${ARTIFACT_DIR}/regions_edge.txt"

# Discovering and testing regions with edge zones.
jq -r '.Regions[] | [.RegionName, .OptInStatus] | @tsv' "${FILE_ALL_REGIONS}" | \
    while read -r line;
do
    rm -rvf "${JUNIT_BUFFER_FILE_MSG}" || true
    region_name=$(echo ${line} | cut -d' ' -f1)
    status=$(echo ${line} | cut -d' ' -f2)

    echo -e "\n**************************\n"
    echo -e "> Processing region ${region_name}" | tee "$JUNIT_BUFFER_FILE_MSG"
    case $status in
    "opted-in"|"opt-in-not-required")
        echo "${region_name}" >> "${ARTIFACT_DIR}/regions_enabled.txt";
        add_test_case "Region ${region_name} is enabled" "0" "pass"
    ;;
    "not-opted-in")
        echo "The region ${region_name} has the status [${status}] which is invalid for this job." | tee -a "${JUNIT_BUFFER_FILE_MSG}"
        add_test_case "Region ${region_name} is enabled" "0" "skipped"
        continue;
    ;;
    # Should not happen. It could be a problem in the parser or invalid API results.
    *)
        echo "The region ${region_name} has invalid status: ${status}." | tee -a "${JUNIT_BUFFER_FILE_MSG}"
        echo "ERROR: Unexpected status [$status] for the Region [${region_name}]. It is expected to be enabled[opted-in|opt-in-not-required] or disabled[not-opted-in]." | tee -a "${JUNIT_BUFFER_FILE_MSG}"
        add_test_case "Region ${region_name} is enabled" "0" "failed"
        continue;
    ;;
    esac

    export AWS_REGION=${region_name}

    test_name="Region ${region_name} support edge zones"
    test_result="pass"
    aws_describe_edge_zones "${region_name}"
    if ! grep "${region_name}" "${ARTIFACT_DIR}/regions_edge.txt"; then
        echo "skip region ${region_name} with no edge zones available." | tee -a "${JUNIT_BUFFER_FILE_MSG}"
        test_result="skipped"
        add_test_case "${test_name}" "0" "${test_result}"
        continue
    fi
    add_test_case "${test_name}" "0" "${test_result}"

    test_name="Region ${region_name} has all edge zones enabled"
    test_result="pass"
    get_enabled_edge_zones "${region_name}"
    if [[ -f "${ARTIFACT_DIR}/edge-zones-disabled_${region_name}.txt" ]] ; then
        echo_date "Detected one or more disabled edge zones, trying to enable it..."
        enable_zones "${region_name}"

        if [[ -f "${ARTIFACT_DIR}/edge-zones-disabled_${region_name}_failed-to-enable.txt" ]] ; then
            echo "One or more zones in the region ${region_name} were not enabled and/or failed to opt-in. Ask the job OWNER to enable the below edge zones manually in AWS EC2 Console." | tee -a "${JUNIT_BUFFER_FILE_MSG}"
            tee -a "$JUNIT_BUFFER_FILE_MSG" < "${ARTIFACT_DIR}/edge-zones-disabled_${region_name}_failed-to-enable.txt"
            test_result="failed"
        fi
    fi
    add_test_case "${test_name}" "0" "${test_result}"

    {
        test_render_single_type "${region_name}" "local-zone"
        test_render_single_type "${region_name}" "wavelength-zone"
        test_render_mixed_type "${region_name}"
        test_render_all_types "${region_name}"
    } | tee -a $JUNIT_BUFFER_FILE_MSG
    add_test_case "Region ${region_name} support edge zones" "0" "pass"
done
