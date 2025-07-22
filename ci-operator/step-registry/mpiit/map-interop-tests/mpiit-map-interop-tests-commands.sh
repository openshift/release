#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'sleep 1h' TERM ERR EXIT SIGINT SIGTERM

curl -L "https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
 -o /tmp/yq && chmod +x /tmp/yq

sleep 1h


#echo "Installing yq-v4"
## Install yq manually if its not found in installer image
#cmd_yq="$(which yq-v4 2>/dev/null || true)"
#if [ ! -x "${cmd_yq}" ]; then
#  curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
#    -o /tmp/bin/yq-v4 && chmod +x /tmp/bin/yq-v4
#fi