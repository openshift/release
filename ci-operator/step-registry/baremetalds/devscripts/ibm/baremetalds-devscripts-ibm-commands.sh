#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts ibm command ************"

# Fetch packet basic configuration
# shellcheck disable=SC1090
source "${SHARED_DIR}/packet-conf.sh"

# Removes IBM custom rpm mirrors and restores community mirrors (CentOS Stream + Rocky)
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set +x

for f in /etc/yum.repos.d/*.repo; do
  if grep -q '^baseurl=.*networklayer\.com' "\$f"; then
    sudo sed -i \
      -e '/^#metalink=/s/^#//' \
      -e '/^#mirrorlist=/s/^#//' \
      -e '/^baseurl=.*networklayer\.com/s/^/#/' \
      "\$f"
  fi
done
EOF
