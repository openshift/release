#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION=${LEASED_RESOURCE}

# https://docs.openshift.com/container-platform/4.15/installing/install_config/configuring-firewall.html#configuring-firewall

cat <<EOF > ${SHARED_DIR}/proxy_whitelist.txt
.cloudfront.net
.s3.${REGION}.amazonaws.com
.s3.amazonaws.com
.s3.dualstack.${REGION}.amazonaws.com
aws.amazon.com
ec2.${REGION}.amazonaws.com
ec2.amazonaws.com
elasticloadbalancing.${REGION}.amazonaws.com
events.amazonaws.com
iam.amazonaws.com
route53.amazonaws.com
servicequotas.${REGION}.amazonaws.com
sts.${REGION}.amazonaws.com
sts.amazonaws.com
tagging.${REGION}.amazonaws.com
tagging.us-east-1.amazonaws.com
EOF

cp ${SHARED_DIR}/proxy_whitelist.txt ${ARTIFACT_DIR}/

# # Proxy in restricted network
# ${proxy_host_address}
# .apps.${CLUSTER_NAME}.${BASE_DOMAIN}
# .s3.${REGION}.amazonaws.com
# .s3.dualstack.${REGION}.amazonaws.com
# ec2.${REGION}.amazonaws.com
# elasticfilesystem.${REGION}.amazonaws.com
# elasticloadbalancing.${REGION}.amazonaws.com
# iam.amazonaws.com
# iam.us-gov.amazonaws.com
# route53.amazonaws.com
# route53.us-gov.amazonaws.com
# sts.${REGION}.amazonaws.com
# sts.amazonaws.com
# tagging.us-east-1.amazonaws.com
# tagging.us-gov-west-1.amazonaws.com
