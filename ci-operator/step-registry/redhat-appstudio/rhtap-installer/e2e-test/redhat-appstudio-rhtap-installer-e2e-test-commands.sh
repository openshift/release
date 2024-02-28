#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -x

cat /etc/*release*

echo "start rhtap-installer e2e test"
nodejs_version=v21.6.2
nodejs_platform=linux-x64
nodejs="node-${nodejs_version}-${nodejs_platform}"

cd /tmp
curl -LO "https://nodejs.org/download/release/${nodejs_version}/${nodejs}.tar.gz"
tar xf "${nodejs}.tar.gz"

export NODEJS_HOME="/tmp/${nodejs}"
export PATH=$PATH:$NODEJS_HOME/bin

HOME=/tmp npm install yarn
export PATH=$PATH:/tmp/node_modules/.bin
cd -

export npm_config_cache="/tmp/.npm"

git clone https://github.com/flacatus/rhtap-e2e.git
cd rhtap-e2e
yarn && yarn test