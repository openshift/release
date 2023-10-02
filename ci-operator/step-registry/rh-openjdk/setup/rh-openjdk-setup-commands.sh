#!/bin/bash

set -u
set -e
set -o pipefail

oc login --insecure-skip-tls-verify=true -u "kubeadmin" -p "$(cat ${KUBEADMIN_PASSWORD_FILE})" "$(oc whoami --show-server)"

oc adm policy add-scc-to-user anyuid -z default

