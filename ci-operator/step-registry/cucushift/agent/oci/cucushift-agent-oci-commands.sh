#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH.
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found."
    exit 1
  fi
fi
curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
/tmp/install.sh --accept-all-defaults

export OCI_CLI_KEY_FILE=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export OCI_CLI_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/oci-config

sleep 1500

