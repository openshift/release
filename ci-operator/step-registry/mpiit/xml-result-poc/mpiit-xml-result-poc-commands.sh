#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq  && touch /tmp/junit.xml
    fi
}

function generateResultFile() {
    results_file="${1}"

    yq eval -n --output-format=xml -I0 '
      .testsuite = {
        "+@name": "MY-lp-interop",
        "+@tests": 1,
        "+@failures": 0,
      }
    ' > $results_file
}

install_yq_if_not_exists
generateResultFile /tmp/junit.xml

# Send junit file to shared dir for Data Router Reporter step
cp /tmp/junit.xml "${SHARED_DIR}"