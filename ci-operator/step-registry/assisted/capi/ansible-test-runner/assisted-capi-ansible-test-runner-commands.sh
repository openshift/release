#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Required env vars
# GITHUB_APP_ID
# GITHUB_APP_INSTALLATION_ID
# GITHUB_APP_PRIVATE_KEY_PATH

NOW=$(date +%s)
IAT=$NOW
EXP=$(($NOW + 600))

HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-')
PAYLOAD=$(echo -n '{"iat":'$IAT',"exp":'$EXP',"iss":"'$GITHUB_APP_ID'"}' | base64 | tr -d '=' | tr '/+' '_-')
SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | openssl dgst -sha256 -sign $GITHUB_APP_PRIVATE_KEY_PATH | openssl base64 -A | tr -d '=' | tr '/+' '_-')

JWT="$HEADER.$PAYLOAD.$SIGNATURE"

INSTALLATION_TOKEN=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/app/installations/$GITHUB_APP_INSTALLATION_ID/access_tokens" \
  | grep -o '"token": "[^"]*' | cut -d'"' -f4)

git config --global url."https://x-access-token:${INSTALLATION_TOKEN}@github.com/".insteadOf "https://github.com/"
git config --global user.name "CAPI version automation"
git config --global user.email "github-app[bot]@users.noreply.github.com"

SSH_KEY_FILE="${CLUSTER_PROFILE_DIR}/packet-private-ssh-key"
SSH_AUTHORIZED_KEY="$(cat ${CLUSTER_PROFILE_DIR}/packet-public-ssh-key)"
REMOTE_HOST=$(cat "${SHARED_DIR}/server-ip")
PULLSECRET=$(cat $CLUSTER_PROFILE_DIR/pull-secret | base64 -w0)
GOCACHE=/tmp
HOME=/tmp
DIST_DIR=/tmp/dist
CONTAINER_TAG=local
export SSH_KEY_FILE
export SSH_AUTHORIZED_KEY
export REMOTE_HOST
export PULLSECRET
export GOCACHE
export HOME
export DIST_DIR
export CONTAINER_TAG

make generate && make manifests && make build-installer
pip install ruamel.yaml

python hack/ansible_test_runner.py

git add release-candidates.yaml
git commit -m "Update release candidates status after testing" || echo "No changes to commit"
git push origin HEAD:${PULL_BASE_REF}
