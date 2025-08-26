#!/bin/bash

set -x
if [[ "${NO_REPORTPORTAL,,}" = 'true' ]]
then
  echo "Skip, as user choose not to send results to ReportPortal for job: ${JOB_NAME}"
  exit 0
fi
# sometimes the test get execute too fast, and JOB_SPEC haven't populated yet
# add sleep and retry logic
jobspec_found='false'
for (( i=0; i<10; i++ ))
do
  if (env | grep -q JOB_SPEC)
  then
    jobspec_found='true'
    break
  fi
  sleep 1
done
if [[ "$jobspec_found" = 'false' ]]
then
  echo "Skip, as no JOB_SPEC defined/found and we rely on it heavily"
  exit 0
fi

ALLOWED_REPOS=('openshift/openshift-tests-private'
               'openshift/rosa'
               'openshift/verification-tests'
               'oadp-qe/oadp-qe-automation'
              )
org="$(jq -r 'if .extra_refs then .extra_refs[0].org
              elif .refs then .refs.org
              else error
              end' <<< ${JOB_SPEC})"
repo="$(jq -r 'if .extra_refs then .extra_refs[0].repo
               elif .refs then .refs.repo
               else error
               end' <<< ${JOB_SPEC})"
# shellcheck disable=SC2076
if ! [[ "${ALLOWED_REPOS[*]}" =~ "$org/$repo" ]]
then
    echo "Skip repository: $org/$repo"
    exit 0
fi

LOGS_PATH='logs'
if [[ "$(jq -r '.type' <<< ${JOB_SPEC})" = 'presubmit' ]]
then
  pr_number="$(jq -r '.refs.pulls[0].number' <<< $JOB_SPEC)"
  if [[ -z "$pr_number" ]]
  then
    echo "Expected pull number not found, exit 1"
    exit 1
  fi
  pr_org="$(jq -r '.refs.org' <<< $JOB_SPEC)"
  pr_repo="$(jq -r '.refs.repo' <<< $JOB_SPEC)"
  if [[ -z "$pr_org" ]] || [[ -z "$pr_repo" ]]
  then
    echo "Expected org/repo name not found, exit 2"
    exit 2
  fi
  LOGS_PATH="pr-logs/pull/${pr_org}_${pr_repo}/${pr_number}"
fi
PROWCI=''
PROWWEB=''
DECK_NAME="$(jq -r 'if .decoration_config and .decoration_config.gcs_configuration
                    then .decoration_config.gcs_configuration.bucket
                    else error
                    end' <<< ${JOB_SPEC})"
if [[ "$DECK_NAME" = 'test-platform-results' ]]
then
  PROWCI='https://prow.ci.openshift.org'
  PROWWEB='https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com'
elif [[ "$DECK_NAME" = 'qe-private-deck' ]]
then
  PROWCI='https://qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com'
  PROWWEB='https://gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com'
else
  echo "Unknow bucket name: $DECK_NAME"
  exit 3
fi
ROOT_PATH="gs://${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}"
LOCAL_DIR="/tmp/${JOB_NAME}/${BUILD_ID}"
LOCAL_DIR_ORI="${LOCAL_DIR}/ori"
LOCAL_DIR_RST="${LOCAL_DIR}/rst"
DATAROUTER_JSON="${LOCAL_DIR}/datarouter.json"
mkdir --parents "$LOCAL_DIR" "$LOCAL_DIR_ORI" "$LOCAL_DIR_RST"

function download_logs() {
  logfile_name="${ARTIFACT_DIR}/rsync.log"
  export PATH="$PATH:/opt/google-cloud-sdk/bin"
  gcloud auth activate-service-account --key-file /var/run/datarouter/gcs_sa_openshift-ci-private
  gsutil -m rsync -r -x '^(?!.*.(finished.json|.xml)$).*' "${ROOT_PATH}/artifacts/${JOB_NAME_SAFE}/" "$LOCAL_DIR_ORI/" &> "$logfile_name"
  gsutil -m rsync -r -x '^(?!.*.(release-images-.*)$).*' "${ROOT_PATH}/artifacts" "$LOCAL_DIR_ORI/" &>> "$logfile_name"
  #gsutil -m cp "${ROOT_PATH}/build-log.txt" "$LOCAL_DIR_ORI/" &>> "$logfile_name"
}

function get_attribute() {
  key_name="$1"
  jq -r '.targets.reportportal.processing.launch.attributes[] | select(.key==$key_name).value' --arg key_name "$key_name" "$DATAROUTER_JSON"
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
  if [[ "$JOB_NAME" =~ amd64|arm64|multi|ppc64le|s390x ]]
  then
    architecture="${BASH_REMATCH[0]}"
  else
    generate_attribute_version_installed
    version_installed="$(get_attribute "version_installed")"
    if [[ "$version_installed" =~ arm64|multi|ppc64le|s390x ]]
    then
      architecture="${BASH_REMATCH[0]}"
    else
      architecture='amd64'
    fi
  fi
  write_attribute architecture "$architecture"
}

function generate_attribute_cloud_provider() {
  if [[ "$JOB_NAME_SAFE" =~ alibaba|aws|azure|baremetal|gcp|ibmcloud|libvirt|nutanix|openstack|powervs|vsphere ]]
  then
    cloud_provider="${BASH_REMATCH[0]}"
    write_attribute cloud_provider "$cloud_provider"
  fi
}

function generate_attribute_env_disconnected() {
  env_disconnected='no'
  if [[ "$JOB_NAME_SAFE" =~ disconnected|-disc- ]]
  then
    env_disconnected='yes'
  fi
  write_attribute env_disconnected "$env_disconnected"
}

function generate_attribute_env_fips() {
  env_fips='no'
  if [[ "$JOB_NAME_SAFE" =~ fips ]]
  then
    env_fips='yes'
  fi
  write_attribute env_fips "$env_fips"
}

function generate_attribute_job_type() {
  job_type='periodic'
  if [[ "$LOGS_PATH" =~ pr-logs ]]
  then
    job_type='presubmit'
  fi
  write_attribute job_type "$job_type"
}

function generate_attribute_install() {
  for keyword in 'cucushift-installer-reportportal-marker' \
                 'idp-htpasswd' \
                 'fips-check-fips-or-die' \
                 'fips-check-node-scan' \
                 'cucushift-pre' \
                 'cucushift-e2e' \
                 'openshift-extended-test' \
                 'openshift-extended-test-longduration' \
                 'openshift-extended-test-supplementary' \
                 'openshift-extended-web-tests' \
                 'openshift-e2e-test-clusterinfra-qe' \
                 'openshift-e2e-test-qe-report'
  do
    if [[ -d "$LOCAL_DIR_ORI/$keyword" ]]
    then
      INSTALL_RESULT="succeed"
      break
    fi
  done
  write_attribute install "$INSTALL_RESULT"
}

function generate_attribute_install_method() {
  if [[ "$JOB_NAME_SAFE" =~ agent|hypershift|ipi|rosa|upi ]]
  then
    install_method="${BASH_REMATCH[0]}"
    write_attribute install_method "$install_method"
    if [[ "$install_method" == "ipi" ]] || [[ "$install_method" == "upi" ]]
    then
      write_attribute install_method_catalog "classic"
    fi
  fi
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

function generate_attribute_pr_author() {
  if [[ "$LOGS_PATH" =~ pr-logs ]]
  then
    pr_author="$(jq -r '.refs.pulls[0].author' <<< $JOB_SPEC)"
    write_attribute pr_author "$pr_author"
  fi
}

function generate_attribute_version_installed() {
  version_installed="$(get_attribute "version_installed")"
  if [[ -z "$version_installed" ]]
  then
    release_dir="${LOCAL_DIR_ORI}/release/artifacts"
    release_info_file="$release_dir/release-images-latest"
    arch="$(get_attribute "architecture")"
    if [[ -z "$arch" ]]
    then
      for release_file in 'release-images-arm64-latest' \
                          'release-images-ppc64le-latest' \
                          'release-images-s390x-latest'
      do
        release_info_file="$release_dir/$release_file"
        if [[ -f "$release_info_file" ]]
        then
          break
        fi
      done
    else
      if [[ "$arch" =~ arm64|ppc64le|s390x ]]
      then
        release_info_file="$release_dir/release-images-${arch}-latest"
      fi
    fi
    if [[ -f "$release_info_file" ]]
    then
      version_installed="$(jq -r '.metadata.name' "$release_info_file")"
      write_attribute version_installed "$version_installed"
    fi
  fi
}

function generate_attributes() {
  generate_attribute_architecture
  generate_attribute_cloud_provider
  generate_attribute_env_disconnected
  generate_attribute_env_fips
  generate_attribute_job_type
  generate_attribute_install
  generate_attribute_install_method
  generate_attribute_profilename
  generate_attribute_pr_author
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
            "description": "${PROWCI}/view/gs/${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}",
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
}

function generate_result_teststeps() {
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
      cat >> "$junit_file" << EOF_JUNIT
  <testcase classname="$testsuite_name" name="$step_name" time="1">
    <system-out>${PROWWEB}/gcs/${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${step_name}/build-log.txt</system-out>
  </testcase>
EOF_JUNIT
      result=$(jq -r '.result' "${file_finished}")
      if [[ "$result" = 'SUCCESS' ]]
      then
        continue
      elif [[ "$result" = 'FAILURE' ]]
      then
        sed -i "\;classname=\"$testsuite_name\" name=\"$step_name\";a \    <failure message=\"Step $step_name failed\" type=\"failed\"/>" "$junit_file"
      fi
    fi
    let failure_count+=1
  done
  sed -i '1 i <?xml version="1.0" encoding="UTF-8"?>' "$junit_file"
  sed -i "1 a <testsuite name=\"$testsuite_name\" failures=\"$failure_count\" errors=\"0\" skipped=\"0\" tests=\"$(wc -w <<< $step_dirs)\">" "$junit_file"
  sed -i '$ a </testsuite>' "$junit_file"
  cp "$junit_file" "${ARTIFACT_DIR}"
}

# For tests in ReportPortal prow project, if install fails, they prefer to log only one failure test case
function generate_result_customize_prow() {
  testsuite_name='Installation'
  # using the same junit filename as the one generated in must-gather step to overwirte installation results
  junit_file="$LOCAL_DIR_RST/junit_install.xml"
  cat > "$junit_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite_name}" failures="0" errors="0" skipped="0" tests="1">
  <testcase classname="${testsuite_name}" name="${testsuite_name}" time="1">
    <system-out>${PROWWEB}/gcs/${DECK_NAME}/${LOGS_PATH}/${JOB_NAME}/${BUILD_ID}/build-log.txt</system-out>
  </testcase>
</testsuite>
EOF
  if [[ "$INSTALL_RESULT" == "fail" ]]
  then
    sed -i 's;failures="0";failures="1";' "$junit_file"
    sed -i '/testcase classname/a \    <failure message="Installation failed" type="failed"/>' "$junit_file"
  fi
}

function generate_results() {
  find "$LOCAL_DIR_ORI" -name "*.xml" ! -name 'junit_cypress-*.xml' -exec cp {} "$LOCAL_DIR_RST" \;

  # For tests in ReportPortal prow project, if install fails, they prefer to log only one failure test case
  if [[ "$REPORTPORTAL_PROJECT" = 'prow' ]]
  then
    generate_result_customize_prow
  else
    generate_result_teststeps
  fi
}

function fix_xmls() {
  # We are updating the copies of the xmls that we will send to DataRouter/ReportPortal,
  # The original xmls are not touched, it should not harm
  xml_files="$(find "$LOCAL_DIR_RST" -name "*.xml")"
  if [[ -z "$xml_files" ]]
  then
    echo 'No xml files to process, exit'
    exit 0
  else
    # when process openshift-e2e-cert-rotation-test/artifacts/junit/junit_e2e__20250806-033347.xml
    # we got: Element 'property': This element is not expected.
    property_xml_files="$(grep -l -r '<property ' $xml_files)" || true
    if [[ -n "$property_xml_files" ]]
    then
      sed -i '\;<property.*</property>;d' $property_xml_files
    fi

    # when process openshift-extended-test-longduration/artifacts/junit/import-Workloads.xml
    # we got: 413 Request Entity Too Large
    # Note: Do NOT replace +10240k with +10M as 'M' is invalid
    # find --help
    #      -size N[bck]    File size is N (c:bytes,k:kbytes,b:512 bytes(def.))
    #                      +/-N: file size is bigger/smaller than N
    large_xml_files="$(find "$LOCAL_DIR_RST" -size +10240k)" || true
    if [[ -n "$large_xml_files" ]]
    then
      for file in $large_xml_files
      do
        grep -B 10 -A 10 -E '<testcase|</testcase>|<failure|</failure>|<system-out|</system-out>' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
      done
    fi
  fi
}

function debug_info() {
  cat "$DATAROUTER_JSON"
  ls -alR "$LOCAL_DIR"
}

function droute_send() {
  /droute version
  droute_send_cmd='/droute send --url="https://datarouter.ccitredhat.com"
                                --username="$(< /var/run/datarouter/username)"
                                --password="$(< /var/run/datarouter/password)"
                                --metadata="$DATAROUTER_JSON"
                                --results="${LOCAL_DIR_RST}/*"
                                --wait
                  '
  for (( i=1; i<=3; i++ ))
  do
    output="$(eval $droute_send_cmd)"
    echo "$output"
    if (grep -q 'request' <<< "$output")
    then
      break
    fi
    echo "Retry 'droute send' after sleep $i minutes"
    sleep ${i}m
  done
}

export INSTALL_RESULT="fail"
download_logs
generate_metadata
generate_results
fix_xmls
debug_info
droute_send
