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


if [ "${SPREADSHEET_NAME}" == "" ]; then
  # Get VERSION
  RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_INITIAL:-}"
  if [[ -z ${RELEASE_IMAGE_INSTALL} ]]; then
    # If there is no initial release, we will be installing latest.
    RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_LATEST:-}"
  fi
  cp "${CLUSTER_PROFILE_DIR}"/pull-secret /tmp/pull-secret
  oc registry login --to /tmp/pull-secret
  VERSION=$(oc adm release info --registry-config /tmp/pull-secret "${RELEASE_IMAGE_INSTALL}" -ojsonpath='{.metadata.version}' | cut -d. -f 1,2 | sed 's/\.//')
  SPREADSHEET_NAME="$VERSION"
fi

echo $SPREADSHEET_NAME > "$SHARED_DIR"/spreadsheet_name

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
OUT_MATCH=${SHARED_DIR}/match.json
OUT_SELECT=${SHARED_DIR}/select.json
OUT_SELECT_DICT=${SHARED_DIR}/select.dict.json


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
  cp "${OUT_MATCH}" "${ARTIFACT_DIR}"/
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

function to_epoch() {
  local dt="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -f "%Y-%m-%d %H:%M:%S%z" "${dt}" +%s
  else
    date -d "${dt}" +%s
  fi
}

function check_condition() {
  local cell_value="$1"
  local expected_value="$2"
  local operator="$3"

  case "$operator" in
  "equals" | "==")
    [[ $cell_value == "$expected_value" ]]
    ;;
  "not_equals" | "!=")
    [[ $cell_value != "$expected_value" ]]
    ;;
  "contains")
    [[ $cell_value == *"$expected_value"* ]]
    ;;
  "starts_with")
    [[ $cell_value == "$expected_value"* ]]
    ;;
  "ends_with")
    [[ $cell_value == *"$expected_value" ]]
    ;;
  "matches" | "regex")
    [[ $cell_value =~ $expected_value ]]
    ;;
  "empty" | "null")
    [[ -z $cell_value ]]
    ;;
  "not_empty" | "not_null")
    [[ -n $cell_value ]]
    ;;
  "days_before")
    if [[ -z $cell_value ]]; then
      [[ $cell_value == "$expected_value" ]]
    else
      epoch_now=$(date +%s)
      epoch_cell=$(to_epoch "$cell_value")
      local delta_seconds delta_days
      delta_seconds=$((epoch_now - epoch_cell))
      delta_days=$((delta_seconds / 86400))
      [ "$delta_days" -gt "$expected_value" ]
    fi
    ;;
  *)
    [[ $cell_value == "$expected_value" ]]
    ;;
  esac
}

function check_row_conditions() {
  local row="$1"
  local headers="$2"
  local conditions="$3"

  local count i
  count=$(echo "$conditions" | jq 'length')

  for ((i = 0; i < count; i++)); do
    local column value operator
    column=$(echo "$conditions" | jq -r --argjson i $i '.[$i].column')
    value=$(echo "$conditions" | jq -r --argjson i $i '.[$i].value')
    operator=$(echo "$conditions" | jq -r --argjson i $i '.[$i].operator // "equals"')

    # find column index
    local column_index
    column_index=$(find_column_index "$headers" "$column")

    if [[ $column_index -eq -1 ]]; then
      echo "warning: column '$column' not found in headers" >&2
      return 1
    fi

    # get cell value from row
    local cell_value
    cell_value=$(echo "$row" | jq -r ".[$column_index] // \"\"")

    if ! check_condition "$cell_value" "$value" "$operator"; then
      return 1
    fi
  done

  return 0
}

function find_matching_rows() {
  local sheet_values_json="$1"
  local conditions_json="$2"
  local out="$3"

  local headers row_count

  headers=$(echo "$sheet_values_json" | jq -r '.[0] // []')
  row_count=$(echo "$sheet_values_json" | jq 'length')

  echo '[]' > "${out}"

  # loop the first-level conditions
  local con1_idx con1_cnt
  con1_cnt=$(echo "$conditions_json" | jq 'length')
  for ((con1_idx = 0; con1_idx < con1_cnt; con1_idx++)); do
    local condition
    condition=$(echo "$conditions_json" | jq -r --argjson con1_idx $con1_idx '.[$con1_idx]')

    local row_idx
    for ((row_idx = 1; row_idx < row_count; row_idx++)); do
      local row
      row=$(echo "$sheet_values_json" | jq -r ".[$row_idx]")
      if check_row_conditions "$row" "$headers" "$condition"; then
        # 1-based
        local match_row match_data match_json
        match_row=$((row_idx + 1))
        match_data=$(echo "$row" | jq -c .)
        match_json="{\"row\": $match_row, \"data\": $match_data}"
        cat <<< "$(jq --argjson match "$match_json" '. += [$match]' "$out")" > "$out"
      fi
    done
  done
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

# ------------------------------------------
# Start
# ------------------------------------------

# check if sheet exist
if ! sheet_exists "${SHEET_NAME_SUMMARY}"; then
  exit 1
fi

# get all sheet's data
get_sheet_data "${SHEET_NAME_SUMMARY}" "${OUT_DATA_SUMMARY}"
HEADERS="$(jq -cr '.[0] // []' "${OUT_DATA_SUMMARY}")"

# create records sheet if not exist.
if ! sheet_exists "${SHEET_NAME_RECORDS}"; then
  # Create records sheet
  create_sheet "${SHEET_NAME_RECORDS}"

  # Add HEADERS
  add_headers "${SHEET_NAME_RECORDS}" "${HEADERS}"
fi

# The Status=Running is being running by another jobs, it won't be selected.
SELECTED_CONDITIONS=$(echo "${CLUSTER_PARAMETER_SELECT_CONDITIONS}" | jq -cr 'map(. + [{"column":"Status","value":"Running","operator":"not_equals"}])')
echo "Seaching record by condition: $(echo "${SELECTED_CONDITIONS}" | jq -cr .)"

find_matching_rows "$(jq -rc . "${OUT_DATA_SUMMARY}")" "${SELECTED_CONDITIONS}" "${OUT_MATCH}"
match_count=$(jq -r '.|length' "${OUT_MATCH}")
echo "Found ${match_count} records match condition."
if [[ ${match_count} == "0" ]]; then
  echo "No match record found, skip test"
  exit 1
else
  # {
  #   "row": 2,
  #   "data": [
  #     "af-south-1",
  #     "default",
  #     "default"
  #   ]
  # }
  selected_record=$(jq -r '.[0]' "${OUT_MATCH}")
  echo "${selected_record}" | jq -r . > "${OUT_SELECT}"

  # convert to kv format
  #
  echo '{}' > "${OUT_SELECT_DICT}"
  for header in $(echo "${HEADERS}" | jq -r '.[]'); do
    idx=$(find_column_index "${HEADERS}" "${header}")
    value="$(jq -r --argjson i "${idx}" '.data[$i] // ""' "${OUT_SELECT}")"
    item="{\"$header\": \"${value}\"}"
    cat <<< "$(jq --argjson item "$item" '. += $item' "$OUT_SELECT_DICT")" > "$OUT_SELECT_DICT"
  done

  echo "Select the first item as the cluster parameter:"
  jq -cr . "${OUT_SELECT}"
  jq -r . "${OUT_SELECT_DICT}"

  # Lock selected record
  echo "Update Status column to \"Running\""
  row_number=$(jq -r '.row' "${OUT_SELECT}")
  existing_data=$(jq -r '.data' "${OUT_SELECT}")
  update_row_by_data_json "${SHEET_NAME_SUMMARY}" "${row_number}" "${existing_data}" "{\"Status\":\"Running\",\"RowUpdated\":\"$(current_date)\"}" "${HEADERS}"
fi
