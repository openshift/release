#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

if [ ! -f "$SHARED_DIR"/spreadsheet_name ]; then
  echo "Can not found spreadsheet_name file."
  exit 1
fi

SPREADSHEET_NAME=$(<"$SHARED_DIR"/spreadsheet_name)

if [ "${SHEET_NAME_PREFIX}" == "" ]; then

  case "${CLUSTER_TYPE}" in
  aws|aws-arm64)
    SHEET_NAME_PREFIX="AWS_${TEST_OBJECT}"
    ;;
  azure4|azure-arm64)
    SHEET_NAME_PREFIX="Azure_${TEST_OBJECT}"
    ;;
  gcp)
    SHEET_NAME_PREFIX="GCP_${TEST_OBJECT}"
    ;;
  *)
    echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
  esac
fi

SHEET_NAME_SUMMARY="${SHEET_NAME_PREFIX}_Summary"
SHEET_NAME_RECORDS="${SHEET_NAME_PREFIX}_Records"

OUT_DATA_SUMMARY=${SHARED_DIR}/${SHEET_NAME_SUMMARY}.json
OUT_SELECT=${SHARED_DIR}/select.json
OUT_SELECT_DICT=${SHARED_DIR}/select.dict.json
OUT_RESULT=${SHARED_DIR}/result.json

if [ ! -f "${OUT_DATA_SUMMARY}" ] || [ ! -f "${OUT_SELECT}" ] || [ ! -f "${OUT_SELECT_DICT}" ] || [ ! -f "${OUT_RESULT}" ]; then
  echo "OUT_DATA_SUMMARY or OUT_SELECT or OUT_SELECT_DICT or OUT_RESULT not found."
  exit 1
fi

function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

# ------------------------------------------
# Setup API Token
# ------------------------------------------
SERVICE_ACCOUNT_KEY_FILE="/var/run/vault/clusters-record/service-account-key.json"
SPREADSHEET_IDS_JSON="/var/run/vault/clusters-record/spreadsheet_ids.json"
SPREADSHEET_ID="$(jq -r --arg n "$SPREADSHEET_NAME" '.[$n]' "${SPREADSHEET_IDS_JSON}")"

if is_empty "$SPREADSHEET_ID"; then
  echo "No SPREADSHEET_ID found for $SPREADSHEET_NAME, please check configuration in Vault."
  exit 1
fi

TOKEN_EXPIRE_IN_MINUTE=60
SPREADSHEET_API_ENDPOINT="https://sheets.googleapis.com/v4/spreadsheets"
ACCESS_TOKEN_FILE=/tmp/access_token

function post_actions() {
  set +e
  echo "Deleting token and secret file ..."
  rm -f "${ACCESS_TOKEN_FILE}"
  rm -f /tmp/pull-secret

  echo "Copying files to ARTIFACT_DIR for debugging ..."
  cp "${OUT_SELECT}" "${ARTIFACT_DIR}"/
  cp "${OUT_RESULT}" "${ARTIFACT_DIR}"/

}
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'post_actions' EXIT TERM INT

function base64encode() { base64 | tr '/+' '_-' | tr -d '=\n'; }

function get_access_token() {
  if [ -z $TOKEN_EXPIRE_IN_MINUTE ]; then
    TOKEN_EXPIRE_IN_MINUTE=60
  fi

  local epoch_now epoch_expire
  local private_key client_email header scope

  epoch_now=$(date +%s)
  epoch_expire=$((epoch_now + TOKEN_EXPIRE_IN_MINUTE))
  private_key=$(jq -r .private_key $SERVICE_ACCOUNT_KEY_FILE)
  client_email=$(jq -r .client_email $SERVICE_ACCOUNT_KEY_FILE)
  header='{"alg":"RS256","typ":"JWT"}'
  scope="https://www.googleapis.com/auth/spreadsheets"

  local claim request_body signature jwt
  claim="{\"iss\": \"${client_email}\", \"scope\": \"${scope}\", \"aud\": \"https://www.googleapis.com/oauth2/v4/token\", \"exp\": \"${epoch_expire}\", \"iat\": \"${epoch_now}\"}"
  request_body="$(echo -n "$header" | base64encode).$(echo -n "$claim" | base64encode)"
  signature=$(openssl dgst -sha256 -sign <(echo -n "$private_key") <(printf '%s' "$request_body") | base64encode)
  jwt="$request_body.$signature"

  local response cmd
  cmd="curl -s -d \"grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}\" https://oauth2.googleapis.com/token"
  response=$(eval "$cmd")
  echo "${response}" | jq -r '.access_token' > "${ACCESS_TOKEN_FILE}"
}

echo "Initializing Google API token ..."
get_access_token "${ACCESS_TOKEN_FILE}"
ACCESS_TOKEN=$(< "${ACCESS_TOKEN_FILE}")
export ACCESS_TOKEN
if [ -z "$ACCESS_TOKEN" ]; then
  log_error "ACCESS_TOKEN not found."
  exit 1
fi

# ------------------------------------------
# Helpers
# ------------------------------------------

function sheet_exists() {
  local sheet_name="$1"
  local response

  echo "Checking if sheet $sheet_name exits ..."
  response=$(curl -s -w "http_status:%{http_code}" -X GET "${SPREADSHEET_API_ENDPOINT}/$SPREADSHEET_ID?fields=sheets.properties.title" -H "Authorization: Bearer $ACCESS_TOKEN")

  body=$(echo "$response" | sed -E 's/http_status\:[0-9]{3}$//')
  http_status=$(echo "$response" | tr -d '\n' | sed -E 's/.*http_status:([0-9]{3})$/\1/')

  if [[ $http_status -eq 200 ]]; then
    if echo "$body" | jq -r '.sheets[].properties.title' | grep -q -w "$sheet_name"; then
      echo "Found."
      return 0
    else
      echo "ERROR: Sheet $sheet_name NOT found."
      return 1
    fi
  else
    echo "Error: Failed to check sheet ${sheet_name}."
    echo "http_status: $http_status"
    echo "error_message:"
    echo "$body" | jq -r '.error.message // "Unknown error"'
    return 2
  fi
}

function get_sheet_data() {
  local sheet_name="$1"
  local out="$2"
  local url response

  echo "Getting sheet $sheet_name data ..."

  url="${SPREADSHEET_API_ENDPOINT}/$SPREADSHEET_ID/values/$sheet_name"
  response=$(curl -s -w "http_status:%{http_code}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    "$url")

  body=$(echo "$response" | sed -E 's/http_status\:[0-9]{3}$//')
  http_status=$(echo "$response" | tr -d '\n' | sed -E 's/.*http_status:([0-9]{3})$/\1/')

  if [[ $http_status -eq 200 ]]; then
    echo "$body" | jq -r '.values' > "${out}"
    echo "Done."
  else
    echo "Error: Failed to get sheet data."
    echo "http_status: $http_status"
    echo "error_message:"
    echo "$body" | jq -r '.error.message // "Unknown error"'
    return 1
  fi
}

function find_column_index() {
  local headers="$1"
  local column_name="$2"

  local header_count
  header_count=$(echo "$headers" | jq 'length')

  for ((k = 0; k < header_count; k++)); do
    local header
    header=$(echo "$headers" | jq -r ".[$k]")
    if [[ $header == "$column_name" ]]; then
      echo "$k"
      return 0
    fi
  done

  echo "-1"
}

function create_sheet() {
  local sheet_name="$1"
  local data response body http_status

  data="{\"requests\": [ {\"addSheet\": {\"properties\": {\"title\": \"${sheet_name}\"}}} ]}"
  response=$(curl -s -w "http_status:%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${SPREADSHEET_API_ENDPOINT}/$SPREADSHEET_ID:batchUpdate")

  body=$(echo "$response" | sed -E 's/http_status\:[0-9]{3}$//')
  http_status=$(echo "$response" | tr -d '\n' | sed -E 's/.*http_status:([0-9]{3})$/\1/')

  if [[ $http_status -eq 200 ]]; then
    echo "Created sheet ${sheet_name}."
  else
    echo "Error: Failed to create sheet."
    echo "http_status: $http_status"
    echo "error_message:"
    echo "$body" | jq -r '.error.message // "Unknown error"'
    return 1
  fi
}

function add_headers() {
  local sheet_name="$1"
  local headers="$2"

  local data response body http_status

  data="{\"values\": [${headers}]}"
  response=$(curl -s -w "http_status:%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${SPREADSHEET_API_ENDPOINT}/${SPREADSHEET_ID}/values/$sheet_name!A1:append?valueInputOption=RAW")

  body=$(echo "$response" | sed -E 's/http_status\:[0-9]{3}$//')
  http_status=$(echo "$response" | tr -d '\n' | sed -E 's/.*http_status:([0-9]{3})$/\1/')

  if [[ $http_status -eq 200 ]]; then
    echo "Added header ${headers} updated successfully"
    echo "Range: $(echo "$body" | jq -r '.updates.updatedRange // "Unknown range"')"
  else
    echo "Error: Failed to add headers."
    echo "http_status: $http_status"
    echo "error_message:"
    echo "$body" | jq -r '.error.message // "Unknown error"'
    return 1
  fi
}

function create_update_row() {
  local existing_data="$1"
  local update_data_json="$2"
  local headers="$3"

  # start with existing data
  local updated_row
  updated_row="$existing_data"

  # get keys from update object
  local update_keys
  update_keys=$(echo "$update_data_json" | jq -r 'keys[]')

  while read -r column; do
    local new_value column_index
    new_value=$(echo "$update_data_json" | jq -r ".[\"$column\"]")
    column_index=$(find_column_index "$headers" "$column")

    if [[ $column_index -ne -1 ]]; then
      # update the specific column in the row
      updated_row=$(echo "$updated_row" | jq ".[$column_index] = \"$new_value\"")
    else
      echo "warning: column '$column' not found in headers" >&2
    fi

  done <<< "$update_keys"

  echo "$updated_row"
}

function update_row_by_data_json() {

  local sheet_name="$1"
  local row_number="$2"
  local existing_data="$3"
  local update_data_json="$4"
  local headers="$5"

  local new_row_data
  new_row_data=$(create_update_row "$existing_data" "$update_data_json" "$headers")
  local range="$sheet_name!A$row_number"
  local url="${SPREADSHEET_API_ENDPOINT}/${SPREADSHEET_ID}/values/$range?valueInputOption=USER_ENTERED"

  local data="{\"values\": [$new_row_data]}"
  echo "Trying to update row ${row_number} in ${sheet_name}"
  echo "Previous Data:"
  echo "$existing_data" | jq -c .
  echo "New Data:"
  echo "$new_row_data" | jq -c .
  local response

  response=$(curl -s -w "http_status:%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "${data}" \
    "$url")

  local body http_status
  body=$(echo "$response" | sed -E 's/http_status\:[0-9]{3}$//')
  http_status=$(echo "$response" | tr -d '\n' | sed -E 's/.*http_status:([0-9]{3})$/\1/')

  if [[ $http_status -eq 200 ]]; then
    echo "Row $row_number updated successfully"
    echo "Range: $(echo "$body" | jq -r '.updatedRange // "Unknown range"')"
    return 0
  else
    echo "error: failed to update row $row_number."
    echo "http_status: $http_status"
    echo "error_message:"
    echo "$body" # | jq -r '.error.message // "Unknown error"'
    return 1
  fi
}

# ------------------------------------------

function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function insert_row_append() {
  local sheet_name="$1"
  local row_data_json="$2"
  local url data response body http_status

  url="${SPREADSHEET_API_ENDPOINT}/$SPREADSHEET_ID/values/$sheet_name:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS"
  data="{\"values\": [$row_data_json]}"

  echo "Trying to append data to ${sheet_name}"
  echo "New Data:"
  echo "${row_data_json}" | jq -cr .

  response=$(curl -s -w "http_status:%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "$url")

  body=$(echo "$response" | sed -E 's/http_status\:[0-9]{3}$//')
  http_status=$(echo "$response" | tr -d '\n' | sed -E 's/.*http_status:([0-9]{3})$/\1/')

  if [[ $http_status -eq 200 ]]; then
    echo "Row appended successfully"
    echo "Range: $(echo "$body" | jq -r '.updates.updatedRange // "Unknown range"')"
    echo "Data: $(echo "$row_data_json" | jq -c .)"
  else
    echo "Error: Failed to append row."
    echo "http_status: $http_status"
    echo "error_message:"
    echo "$body" | jq -r '.error.message // "Unknown error"'
    return 1
  fi
}

function append_row_by_data_json() {

  local sheet_name="$1"
  local update_data_json="$2"
  local headers="$3"
  local existing_data='[]'
  local new_row_data
  new_row_data=$(create_update_row "$existing_data" "$update_data_json" "$headers")
  insert_row_append "${sheet_name}" "${new_row_data}"
}

# ------------------------------------------
# Start
# ------------------------------------------

# check if sheet exist
if ! sheet_exists "${SHEET_NAME_SUMMARY}"; then
  exit 1
fi

HEADERS="$(jq -cr '.[0] // []' "${OUT_DATA_SUMMARY}")"

if ! sheet_exists "${SHEET_NAME_RECORDS}"; then
  # Create records sheet
  create_sheet "${SHEET_NAME_RECORDS}"

  # Add HEADERS
  add_headers "${SHEET_NAME_RECORDS}" "${HEADERS}"
fi

# -------------------------
# health check result
# -------------------------

echo "Checking health check result ..."
if [ -f "${SHARED_DIR}"/install-health-check-status.txt ]; then
  healthcheck_ret=$(< "${SHARED_DIR}"/install-health-check-status.txt)
  echo "Health check ret: $healthcheck_ret"
  if [ "$healthcheck_ret" == "0" ]; then
    HEALTHCHECK_RESULT="PASS"
  else
    HEALTHCHECK_RESULT="FAIL"
  fi
else
  echo "Health check failed: No health check was performed."
  HEALTHCHECK_RESULT="FAIL"
fi

# Update result
OVERALL_RESULT="PASS"

INSTALL_RESULT=$(jq -r '.Install' "$OUT_RESULT")
DESTROY_RESULT=$(jq -r '.Destroy' "$OUT_RESULT")
if [ "$INSTALL_RESULT" != "PASS" ] || [ "$HEALTHCHECK_RESULT" != "PASS" ] || [ "$DESTROY_RESULT" != "PASS" ]; then
    OVERALL_RESULT="FAIL"
fi

# -------------------------
# storage check result
# openshift-extended-test:
#   total: 1
#   failures: 0
#   errors: 0
#   skipped: 0
TEST_RESULT_FILE="${SHARED_DIR}"/openshift-e2e-test-qe-report

if [ -f "$TEST_RESULT_FILE" ]; then
  total=$(yq-v4 e '.openshift-extended-test.total' "$TEST_RESULT_FILE")
  failures=$(yq-v4 e '.openshift-extended-test.failures' "$TEST_RESULT_FILE")
  errors=$(yq-v4 e '.openshift-extended-test.errors' "$TEST_RESULT_FILE")
  skipped=$(yq-v4 e '.openshift-extended-test.skipped' "$TEST_RESULT_FILE")

  if [ "$total" -gt "0" ] && [ "$failures" -eq "0" ] && [ "$errors" -eq "0" ] && [ "$skipped" -eq "0" ]; then
    STORAGE_CHECK_RESULT="PASS"
  else
    STORAGE_CHECK_RESULT="FAIL"
  fi
  echo "Storage test result: $STORAGE_CHECK_RESULT"
  cat "$TEST_RESULT_FILE"
else
  # No no e2e test
  echo "No storage check, skip check."
  STORAGE_CHECK_RESULT="N/A"
fi

if [ "$STORAGE_CHECK_RESULT" == "FAIL" ]; then
  OVERALL_RESULT="FAIL"
fi

case "${CLUSTER_TYPE}" in
aws|aws-arm64)
  AMI_RESULT=$(jq -r '.AMI' "$OUT_RESULT")
  if [ "$AMI_RESULT" != "PASS" ]; then
    OVERALL_RESULT="FAIL"
  fi
  ;;
azure4|azure-arm64)
  ;;
gcp)
  ;;
*)
  echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

# -------------------
# Job URL
# -------------------
JOB_URL="None"

job_type=$(echo "${JOB_SPEC}" | jq -r '.type // ""')
if [ "$job_type" == "periodic" ]; then
  job_url_prefix="https://qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/view/"
  job_bucket=$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.bucket // ""')
  job_name=$(echo "${JOB_SPEC}" | jq -r '.job // ""')
  job_buildid=$(echo "${JOB_SPEC}" | jq -r '.buildid // ""')
  JOB_URL="${job_url_prefix}gs/${job_bucket}/logs/${job_name}/${job_buildid}"
fi

if [ "$job_type" == "presubmit" ]; then
  job_url_prefix=$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.job_url_prefix // ""')
  job_bucket=$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.bucket // ""')
  job_pr=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number // ""')
  job_name=$(echo "${JOB_SPEC}" | jq -r '.job // ""')
  job_buildid=$(echo "${JOB_SPEC}" | jq -r '.buildid // ""')
  JOB_URL="${job_url_prefix}gs/${job_bucket}/pr-logs/pull/openshift_release/${job_pr}/${job_name}/${job_buildid}"
fi

update_result "URL" "${JOB_URL}"

update_result "Status" "Completed"
update_result "Health" "${HEALTHCHECK_RESULT}"
update_result "Storage" "${STORAGE_CHECK_RESULT}"
update_result "OverallResult" "${OVERALL_RESULT}"
update_result "RowUpdated" "$(current_date)"

# insert result to details
echo "Appending the result to the details' page ..."
data="$(jq -cr . "${OUT_RESULT}")"
append_row_by_data_json "${SHEET_NAME_RECORDS}" "${data}" "${HEADERS}"

# Summarize result and update to Overall sheet
echo "Updating Overrall page ..."

# out_records data sample:
# [
#   [ "Region", "ControlPlaneType", ... ],
#   [ "af-south-1", "default", ... ],
#   [ "us-east-1", "default", ... ],
#   ...
# ]
# the first item is header name
out_records=$(mktemp)
get_sheet_data "${SHEET_NAME_RECORDS}" "${out_records}"

# There may be multi results, e.g. serval PASS results
# candidate_results file stores these results:
# [
#   {
#     "Region": "us-east-2",
#     "ControlPlaneType": "default",
#     "ComputeType": "default",
#     "OverallResult": "PASS",
#      ...
#   },
#   ...
# ]
echo "Selecting candidate results from details page ..."
candidate_results=$(mktemp)

# Convert to KV format
# [
#   [
#     "Region",
#     "Arch",
#     ...
#   ],
#   [
#     "af-south-1",
#     "amd64",
#     ...
#   ]
#   ...
# ]
#
# To
#
# [
#   {
#     "Region": "af-south-1",
#     "Arch": "amd64",
#     ...
#   },
#   ...
# ]

jq '.[0] as $headers | [.[1:][] | [., $headers] | transpose | map({(.[1]): .[0]}) | add]' "${out_records}" > "$candidate_results"

# Filter results by each key
for column in $(echo "$RESULT_SELECT_BY_COLUMNS" | jq -r '.[]');
do
  value="$(jq -r --arg c "$column" '.[$c]' "$OUT_SELECT_DICT")"
  cat <<< "$(jq -r --arg c "$column" --arg v "$value" 'map(select(.[$c] == $v))' "$candidate_results")" > "$candidate_results"
done

cat <<< "$(jq -r 'map(select(.OverallResult == "PASS")) | sort_by( (.CreatedDate | sub(",[ ]*$"; "") | strptime("%Y-%m-%d %H:%M:%S%z") | mktime) ) | reverse' "$candidate_results")" > "$candidate_results"

echo "candidate results: $(jq -cr . "${candidate_results}")"

count=$(jq -r '.|length' "${candidate_results}")
if [[ ${count} == "0" ]]; then
  echo "No latest PASS, using the latest FAILED result"
  selected_overall_result="$(jq -r '.' "${OUT_RESULT}")"
else
  selected_overall_result="$(jq -r '.[0]' "${candidate_results}")"
fi

selected_overall_result_with_update_time=$(echo "$selected_overall_result" | jq --arg u "$(current_date)" '.RowUpdated = $u')
echo "Selected Overall result: $(echo "${selected_overall_result_with_update_time}" | jq -cr .)"

echo "Updating result to overrall page"
row_number=$(jq -r '.row' "${OUT_SELECT}")
existing_data=$(jq -r '.data' "${OUT_SELECT}")
update_row_by_data_json "${SHEET_NAME_SUMMARY}" "${row_number}" "${existing_data}" "${selected_overall_result_with_update_time}" "${HEADERS}"

echo "All done."
