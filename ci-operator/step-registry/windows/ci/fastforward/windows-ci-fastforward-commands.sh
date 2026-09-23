#!/bin/bash
set -eo pipefail

function get_app_id() {
  app_id=$(cat $GITHUB_APP_ID_PATH)
  echo "${app_id}"
}

function get_app_private_key() {
  private_key=$(cat $GITHUB_APP_PRIVATE_KEY_PATH)
  # check the private key for trailing newlines
  if [[ $private_key == *'\n'* ]]; then
      private_key=$(echo -e $private_key)
  fi
  echo "${private_key}"
}

function build_payload() {
  jq -c \
  --arg iat_str "$(date +%s)" \
  --arg app_id "${app_id}" \
  '
      ($iat_str | tonumber) as $iat
      | .iat = $iat
      | .exp = ($iat + 300)
      | .iss = (app_id | tonumber)
      ' <<<"${payload_template}" | tr -d '\n'
}

function b64enc() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '=';
}

function json() {
  jq -c . | LC_CTYPE=C tr -d '\n';
}

function rs256_sign() {
  openssl dgst -binary -sha256 -sign <(printf '%s\n' "$1");
}

function sign() {
  local payload sig
  private_key=$(get_app_private_key) || return
  payload=$(build_payload) || return
  signed_content="$(json <<<"$header" | b64enc).$(json <<<"$payload" | b64enc)"
  sig=$(printf %s "$signed_content" | rs256_sign "$private_key" | b64enc)
  printf '%s.%s\n' "${signed_content}" "${sig}"
}

function generate_access_token(){
  # requires app_id to be set
  if [[ -z "$app_id" ]]; then
      echo "ERROR app_id cannot not be empty"
      exit 1
  fi
  auth_token=$(sign)

  installations=$(curl -s -H "Authorization: Bearer ${auth_token}" \
      -H "Accept: application/vnd.github.machine-man-preview+json" \
      https://api.github.com/app/installations)

  # find the installations for the openshift organization
  installation_id=$(echo $installations | jq '.[] | select(.account.login=="openshift")' | jq -r '.id')
  # must be 1 installation for WMCO repo only
  openshift_installation_count=$(echo $installation_id | wc -w)
  if [[ $openshift_installation_count -ne 1 ]]; then
    >&2 echo "Cannot find unique installation in Openshift organization, found: $openshift_installation_count"
    return 1
  fi

  token_response=$(curl -s -X POST \
          -H "Authorization: Bearer ${auth_token}" \
          -H "Accept: application/vnd.github.machine-man-preview+json" \
          https://api.github.com/app/installations/$installation_id/access_tokens)

  access_token=$(echo $token_response | jq -r '.token')
  if [ -z "$access_token" ];
  then
     >&2 echo "Unable to obtain access token for installation ${installation_id}"
     exit 1
  fi
  # return the access token
  echo "${access_token}"
}

wmco_dir=$(mktemp -d -t wmco-XXXXX)
cd "$wmco_dir" || exit 1

echo "INFO Checking settings"
echo "    GITHUB_APP_ID_PATH          = $GITHUB_APP_ID_PATH"
echo "    GITHUB_APP_PRIVATE_KEY_PATH = $GITHUB_APP_PRIVATE_KEY_PATH"
echo "    REPO_OWNER                  = $REPO_OWNER"
echo "    REPO_NAME                   = $REPO_NAME"
echo "    JOB_TYPE                    = $JOB_TYPE"
echo "    SOURCE_BRANCH               = $SOURCE_BRANCH"
echo "    DESTINATION_BRANCH          = $DESTINATION_BRANCH"

if [[ "$JOB_TYPE" != "postsubmit" ]]; then
    echo "ERROR This workflow may only be run as a postsubmit job"
    exit 1
fi

if [[ ! -r "${GITHUB_APP_ID_PATH}" ]]; then
    echo "ERROR GITHUB_APP_ID_PATH missing or not readable"
    exit 1
fi

if [[ ! -r "${GITHUB_APP_PRIVATE_KEY_PATH}" ]]; then
    echo "ERROR GITHUB_APP_PRIVATE_KEY_PATH missing or not readable"
    exit 1
fi

if [[ -z "$SOURCE_BRANCH" ]]; then
    echo "ERROR SOURCE_BRANCH may not be empty"
    exit 1
fi

if [[ -z "$DESTINATION_BRANCH" ]]; then
    echo "ERROR DESTINATION_BRANCH may not be empty"
    exit 1
fi

# setup required variables
header='{
    "alg": "RS256",
    "typ": "JWT"
}'
payload_template='{}'

app_id=$(get_app_id)
app_username="openshift-winc-community-rebase"
app_email="${app_id}+${app_username}[bot]@users.noreply.github.com"

export app_id
export app_username
export app_email

echo "INFO Generating access token for application id $app_id"
access_token=$(generate_access_token)

echo "INFO setting access token in URL for $REPO_OWNER/$REPO_NAME"
repo_url="https://x-access-token:${access_token}@github.com/$REPO_OWNER/$REPO_NAME.git"

echo "INFO Cloning $DESTINATION_BRANCH"
if ! git clone -b "$DESTINATION_BRANCH" "$repo_url" ; then
    echo "INFO $DESTINATION_BRANCH does not exist. Will create it"
    echo "INFO Cloning $SOURCE_BRANCH"
    if ! git clone -b "$SOURCE_BRANCH" "$repo_url" ; then
        echo "ERROR Could not clone $SOURCE_BRANCH"
        echo "      repo_url = $repo_url"
        exit 1
    fi

    echo "INFO Changing into repo directory"
    cd "$REPO_NAME" || exit 1
    git config --local user.name "${app_username}"
    git config --local user.email "${app_email}"

    echo "INFO Checking out new $DESTINATION_BRANCH"
    if ! git checkout -b "$DESTINATION_BRANCH" ; then
        echo "ERROR Could not checkout $DESTINATION_BRANCH"
        exit 1
    fi

    echo "INFO Pushing to new branch $DESTINATION_BRANCH"
    if ! git push origin "$DESTINATION_BRANCH" ; then
        echo "ERROR Could not push to origin $DESTINATION_BRANCH"
        exit 1
    fi

    echo "INFO Fast forward complete"
    exit 0
fi

echo "INFO Changing into repo directory"
cd "$REPO_NAME" || exit 1
git config --local user.name "${app_username}"
git config --local user.email "${app_email}"

echo "INFO Pulling from $SOURCE_BRANCH into $DESTINATION_BRANCH"
if ! git pull --ff-only origin "$SOURCE_BRANCH" ; then
    echo "ERROR Could not pull from $SOURCE_BRANCH"
    exit 1
fi

echo "INFO Pushing the following commits to origin/$DESTINATION_BRANCH"
git --no-pager log --pretty=oneline origin/"$DESTINATION_BRANCH"..HEAD
if ! git push origin "$DESTINATION_BRANCH"; then
    echo "ERROR Could not push to $DESTINATION_BRANCH"
   exit 1
fi

echo "INFO Fast forward complete"

