#!/bin/bash

set -o pipefail

# the exit code of this step is not expected to be caught from the overall test suite in ReportPortal. Excluding it
touch "${ARTIFACT_DIR}/skip_overall_if_fail"

set -x
LOGS_PATH="logs"
if [[ "$(jq -r '.type' <<< ${JOB_SPEC:-''})" = "presubmit" ]]
then
  pr_number="$(jq -r '.refs.pulls[0].number' <<< $JOB_SPEC)"
  if [[ -z "$pr_number" ]]
  then
    echo "Expected pull number not found, exit 1"
    exit 1
  fi
  LOGS_PATH="pr-logs/pull/openshift_release/${pr_number}"
fi
ROOT_PATH="gs://${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}"
LOCAL_DIR="/tmp/${JOB_NAME}/${BUILD_ID}"
LOCAL_DIR_ORI="${LOCAL_DIR}/ori"
LOCAL_DIR_RST="${LOCAL_DIR}/rst"
DATAROUTER_JSON="${LOCAL_DIR}/datarouter.json"
mkdir --parents "$LOCAL_DIR" "$LOCAL_DIR_ORI" "$LOCAL_DIR_RST"

function download_logs() {
  logfile_name="${ARTIFACT_DIR}/rsync.log"
  gcloud auth activate-service-account --key-file /var/run/datarouter/gcs_sa_openshift-ci-private
  gsutil -m rsync -r -x '^(?!.*.(finished.json|.xml|build-log.txt|skip_overall_if_fail)$).*' "${ROOT_PATH}/artifacts/${JOB_NAME_SAFE}/" "$LOCAL_DIR_ORI/" &> "$logfile_name"
  gsutil -m rsync -r -x '^(?!.*.(release-images-.*)$).*' "${ROOT_PATH}/artifacts" "$LOCAL_DIR_ORI/" &>> "$logfile_name"
  #gsutil -m cp "${ROOT_PATH}/build-log.txt" "$LOCAL_DIR_ORI/" &>> "$logfile_name"
}

function write_attribute() {
  key_name="$1"
  key_value="$2"
  tmp_file="/tmp/temp_datarouter_$$.tmp"
  if jq '.targets.reportportal.processing.launch.attributes += [{"key": $key_name, "value": $key_value}]' --arg key_name "$key_name" --arg key_value "$key_value" "$DATAROUTER_JSON" > "$tmp_file"
  then
    mv -f "$tmp_file" "$DATAROUTER_JSON"
  else
    rm -f "$tmp_file"
  fi
}

function generate_attribute_architecture() {
  architecture="unknown"
  for keyword in 'amd64' \
                 'arm64' \
                 'multi' \
                 'ppc64le'
  do
    if [[ "$JOB_NAME" =~ $keyword ]] ; then
      architecture="$keyword"
      break
    fi
  done
  write_attribute architecture "$architecture"
}

function generate_attribute_cloud_provider() {
  cloud_provider="unknown"
  for keyword in 'alibaba' \
                 'aws' \
                 'azure' \
                 'baremetal' \
                 'gcp' \
                 'ibmcloud' \
                 'libvirt' \
                 'nutanix' \
                 'openstack' \
                 'vsphere'
  do
    if [[ "$JOB_NAME_SAFE" =~ $keyword ]] ; then
      cloud_provider="$keyword"
      break
    fi
  done
  write_attribute cloud_provider "$cloud_provider"
}

function generate_attribute_install_method() {
  install_method="unknown"
  for keyword in 'agent' \
                 'hypershift' \
                 'ipi' \
                 'rosa' \
                 'upi'
  do
    if [[ "$JOB_NAME_SAFE" =~ $keyword ]] ; then
      install_method="$keyword"
      break
    fi
  done
  write_attribute install_method "$install_method"
}

function generate_attribute_profilename() {
  profile_name="$(sed -E 's/-[fp][0-9]+//g' <<< "$JOB_NAME_SAFE")"
  for keyword in '-destructive' \
                 '-disruptive' \
                 '-long-duration' \
                 '-longrun'
  do
    profile_name="${profile_name/$keyword/}"
  done
  write_attribute profilename "$profile_name"
}

function generate_attribute_version_installed() {
  version_installed="unknown"
  release_dir="${LOCAL_DIR_ORI}/release/artifacts"
  release_file="release-images-latest"
  arch="$(jq -r '.targets.reportportal.processing.launch.attributes[] | select(.key=="architecture").value' "$DATAROUTER_JSON")"
  if [[ "$arch" = 'arm64' ]]
  then
    release_file="release-images-arm64-latest"
  fi
  release_info_file="$release_dir/$release_file"
  if [[ -f "$release_info_file" ]]
  then
    version_installed="$(jq -r '.metadata.name' "$release_info_file")"
  fi
  write_attribute version_installed "$version_installed"
}

function generate_attributes() {
  generate_attribute_architecture
  generate_attribute_cloud_provider
  generate_attribute_install_method
  generate_attribute_profilename
  generate_attribute_version_installed
}

function generate_metadata() {
  cat > "$DATAROUTER_JSON" << EOF_JSON
  {
    "targets": {
      "reportportal": {
        "config": {
          "hostname": "${REPORTPORTAL_HOSTNAME}",
          "project": "${REPORTPORTAL_PROJECT}"
        },
        "processing": {
          "apply_tfa": ${APPLY_TFA},
          "disable_testitem_updater": ${DISABLE_TESTITEM_UPDATER},
          "launch": {
            "attributes": [
              {
                "key": "build_id",
                "value": "${BUILD_ID}"
              },
              {
                "key": "jobname",
                "value": "${JOB_NAME_SAFE}"
              },
              {
                "key": "namespace",
                "value": "${NAMESPACE}"
              },
              {
                "key": "uploadfrom",
                "value": "prow"
              }
            ],
            "description": "https://qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/view/gs/${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}",
            "name": "${JOB_NAME}"
          },
          "property_filter": [
            ".*"
          ]
        }
      }
    }
  }
EOF_JSON

  generate_attributes
  cat "$DATAROUTER_JSON"
}

function generate_results() {
  testsuite_name='Overall CI (test step)'
  junit_file="$LOCAL_DIR_RST/junit_test-steps.xml"
  failure_count=0
  step_dirs=$(find "$LOCAL_DIR_ORI" -maxdepth 1 -mindepth 1 -type d | grep -v '/release$' | sort)
  for step_dir in $step_dirs
  do
    step_name="$(basename "${step_dir}")"
    file_finished="${step_dir}/finished.json"
    if [ -f "${file_finished}" ]
    then
      result=$(jq -r '.result' "${file_finished}")
      if [[ "$result" = 'SUCCESS' ]]
      then
        cat >> "$junit_file" << EOF_JUNIT_SUCCESS
  <testcase classname="$testsuite_name" name="$step_name" time="1">
    <system-out>https://gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${step_name}/build-log.txt</system-out>
  </testcase>
EOF_JUNIT_SUCCESS
      elif [[ "$result" = 'FAILURE' ]]
      then
        let failure_count+=1
        cat >> "$junit_file" << EOF_JUNIT_FAILURE
  <testcase classname="$testsuite_name" name="$step_name" time="1">
    <failure message="Step $step_name failed" type="failed"/>
    <system-out>https://gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${step_name}/build-log.txt</system-out>
  </testcase>
EOF_JUNIT_FAILURE
      fi
    else
      let failure_count+=1
    fi
  done
  sed -i '1 i <?xml version="1.0" encoding="UTF-8"?>' "$junit_file"
  sed -i "1 a <testsuite name=\"$testsuite_name\" failures=\"$failure_count\" errors=\"0\" skipped=\"0\" tests=\"$(wc -w <<< $step_dirs)\">" "$junit_file"
  sed -i '$ a </testsuite>' "$junit_file"
  cp "$junit_file" "${ARTIFACT_DIR}"
  find "$LOCAL_DIR_ORI" -name "*.xml" ! -name 'junit_cypress-*.xml' -exec cp {} "$LOCAL_DIR_RST" \;

  ls -alR "$LOCAL_DIR"
}

function droute_send() {
  which droute && droute version
  droute send --url="$(< /var/run/datarouter/dataroute)" \
              --username="$(< /var/run/datarouter/username)" \
              --password="$(< /var/run/datarouter/password)" \
              --metadata="$DATAROUTER_JSON" \
              --results="${LOCAL_DIR_RST}/*"
}

download_logs
generate_metadata
generate_results
droute_send
