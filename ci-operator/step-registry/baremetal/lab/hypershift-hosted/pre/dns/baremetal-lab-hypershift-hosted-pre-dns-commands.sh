#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

HOSTED_CLUSTER_NAME="$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c-20)"
echo "$HOSTED_CLUSTER_NAME" > "$SHARED_DIR"/hostedcluster_name

# shellcheck disable=SC1090
. <(yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")' < "${SHARED_DIR}"/external_vips_hypershift_hosted.yaml)
# shellcheck disable=SC2154
if [ ${#api_vip} -eq 0 ] || [ ${#ingress_vip} -eq 0 ]; then
  echo "Unable to parse VIPs"
  exit 1
fi

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
DNS_FORWARD=";DO NOT EDIT; BEGIN $CLUSTER_NAME
api.${HOSTED_CLUSTER_NAME}.${CLUSTER_NAME} IN A ${api_vip}
api-int.${HOSTED_CLUSTER_NAME}.${CLUSTER_NAME} IN A ${api_vip}
*.apps.${HOSTED_CLUSTER_NAME}.${CLUSTER_NAME} IN A ${api_vip}
;DO NOT EDIT; END $CLUSTER_NAME"

# TODO: why isn't hypershift using api-int for the internal API, e.g., for ignition and konnectivity?
# The hostedclusters resource can allow configuring this endpoint, but it's not used in CI yet.
# In the future, we may want to pivot to a configuration that makes use of api-int for services that should
# be internal-only, and api for services that should be externally accessible.
# This might be part of a larger effort that includes documenting this behavor for users too.

echo "Installing the following forward dns:"
echo -e "$DNS_FORWARD"

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "'${DNS_FORWARD}'" << 'EOF'
set -o nounset
set -o errexit
echo -e "${1}" >> /opt/bind9_zones/zone
echo "Increasing the zones serial..."
sed -i "s/^.*; serial/$(date +%s); serial/" /opt/bind9_zones/{zone,internal_zone.rev}
podman exec bind9 rndc reload
podman exec bind9 rndc flush
EOF
