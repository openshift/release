#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"


# subnet, AZs and hosted zone
HOSTED_ZONE_ID_FILE="${SHARED_DIR}/hosted_zone_id"

if [ ! -f "${HOSTED_ZONE_ID_FILE}" ]; then
    echo "File ${HOSTED_ZONE_ID_FILE} does not exist."
    exit 1
fi
HOSTED_ZONE_ID="$(cat ${HOSTED_ZONE_ID_FILE})"

echo -e "hosted zone: ${HOSTED_ZONE_ID}"

CONFIG_ROUTE53_PRIVATE_HOSTEDZONE="/tmp/install-config-route53-private-hosted-zone.yaml.patch"
cat > "${CONFIG_ROUTE53_PRIVATE_HOSTEDZONE}" << EOF
platform:
  aws:
    hostedZone: ${HOSTED_ZONE_ID}
EOF

yq-go m -x -i "${CONFIG}" "${CONFIG_ROUTE53_PRIVATE_HOSTEDZONE}"
echo "Hosted Zone:"
cat ${CONFIG_ROUTE53_PRIVATE_HOSTEDZONE}

if [[ ${ENABLE_SHARED_PHZ} == "yes" ]]; then
  ROLE_ARN=$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn")

  if [[ "${ROLE_ARN}" == "" ]]; then
    echo "ERROR: hosted zone role arn is empty, exit now"
    exit 1
  fi
  echo "hosted zone role arn: ${ROLE_ARN}"
  CONFIG_ROUTE53_PRIVATE_HOSTEDZONE_ROLE="/tmp/install-config-route53-private-hosted-zone-role.yaml.patch"
  cat > "${CONFIG_ROUTE53_PRIVATE_HOSTEDZONE_ROLE}" << EOF
platform:
  aws:
    hostedZoneRole: $ROLE_ARN
EOF
  yq-go m -x -i "${CONFIG}" "${CONFIG_ROUTE53_PRIVATE_HOSTEDZONE_ROLE}"
  echo "Hosted Zone Role:"
  cat ${CONFIG_ROUTE53_PRIVATE_HOSTEDZONE_ROLE}
fi