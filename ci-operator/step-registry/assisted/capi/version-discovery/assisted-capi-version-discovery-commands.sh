#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

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

export GITHUB_APP_ID
export GITHUB_APP_INSTALLATION_ID
export GITHUB_APP_PRIVATE_KEY_PATH

python hack/version_discovery.py

git add release-candidates.yaml
git commit -m "Update release candidates"
git push origin HEAD:${PULL_BASE_REF}
