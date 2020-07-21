#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-blackholenetwork.yaml.patch"

aws_region=$(/tmp/yq r "${CONFIG}" 'platform.aws.region')

subnets="[]"
case "${aws_region}" in
us-east-1) subnets="['subnet-0a7491aa76f9b88d7','subnet-0f0b2dcccdcbc7c1d','subnet-0680badf68cbf198c','subnet-02b25dd65f806e41b','subnet-010235a3bff34cf6f','subnet-085c78d8c562b5a51']";;
us-east-2) subnets="['subnet-0ea117d9499ef624f','subnet-00adc83d4719d4176','subnet-0b9399990fa424d7f','subnet-060d997b25f5bb922','subnet-015f4e65b0ef1b0e1','subnet-02296b47817923bfb']";;
us-west-1) subnets="['subnet-0d003f08a541855a2','subnet-04007c47f50891b1d','subnet-02cdb70a3a4beb754','subnet-0d813eca318034290']";;
us-west-2) subnets="['subnet-05d8f8ae35e720611','subnet-0f3f254b13d40e352','subnet-0e23da17ea081d614','subnet-0f380906f83c55df7','subnet-0a2c5167d94c1a5f8','subnet-01375df3b11699b77']";;
*) echo >&2 "invalid subnets index"; exit 1;;
esac
echo "Subnets : ${subnets}"

cat >> "${PATCH}" << EOF
platform:
  aws:
    subnets: ${subnets}
EOF

/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
