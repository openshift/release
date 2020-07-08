#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-sharednetwork.yaml.patch"

aws_region=$(/tmp/yq r "${CONFIG}" 'platform.aws.region')

subnets="[]"
case "${aws_region}_$((RANDOM % 4))" in
us-east-1_0) subnets="['subnet-030a88e6e97101ab2','subnet-0e07763243186cac5','subnet-02c5fea7482f804fb','subnet-0291499fd1718ee01','subnet-01c4667ad446c8337','subnet-025e9043c44114baa']";;
us-east-1_1) subnets="['subnet-0170ee5ccdd7e7823','subnet-0d50cac95bebb5a6e','subnet-0094864467fc2e737','subnet-0daa3919d85296eb6','subnet-0ab1e11d3ed63cc97','subnet-07681ad7ce2b6c281']";;
us-east-1_2) subnets="['subnet-00de9462cf29cd3d3','subnet-06595d2851257b4df','subnet-04bbfdd9ca1b67e74','subnet-096992ef7d807f6b4','subnet-0b3d7ba41fc6278b2','subnet-0b99293450e2edb13']";;
us-east-1_3) subnets="['subnet-047f6294332aa3c1c','subnet-0c3bce80bbc2c8f1c','subnet-038c38c7d96364d7f','subnet-027a025e9d9db95ce','subnet-04d9008469025b101','subnet-02f75024b00b20a75']";;
us-east-2_0) subnets="['subnet-0a568760cd74bf1d7','subnet-0320ee5b3bb78863e','subnet-015658a21d26e55b7','subnet-0c3ce64c4066f37c7','subnet-0d57b6b056e1ee8f6','subnet-0b118b86d1517483a']";;
us-east-2_1) subnets="['subnet-0f6c106c48187d0a9','subnet-0d543986b85c9f106','subnet-05ef94f36de5ac8c4','subnet-031cdc26c71c66e83','subnet-0f1e0d62680e8b883','subnet-00e92f507a7cbd8ac']";;
us-east-2_2) subnets="['subnet-0310771820ebb25c7','subnet-0396465c0cb089722','subnet-02e316495d39ce361','subnet-0c5bae9b575f1b9af','subnet-0b3de1f0336c54cfe','subnet-03f164174ccbc1c60']";;
us-east-2_3) subnets="['subnet-045c43b4de0092f74','subnet-0a78d4ddcc6434061','subnet-0ed28342940ef5902','subnet-02229d912f99fc84f','subnet-0c9b3aaa6a1ad2030','subnet-0c93fb4760f95dbe4']";;
us-west-1_0) subnets="['subnet-0919ede122e5d3e46','subnet-0cf9da97d102fff0d','subnet-000378d8042931770','subnet-0c8720acadbb099fc']";;
us-west-1_1) subnets="['subnet-0129b0f0405beca97','subnet-073caab166af2207e','subnet-0f07362330db0ac66','subnet-007d6444690f88b33']";;
us-west-1_2) subnets="['subnet-09affff50a1a3a9d0','subnet-0838fdfcbe4da6471','subnet-08b9c065aefd9b8de','subnet-027fcc48c429b9865']";;
us-west-1_3) subnets="['subnet-0cd3dde41e1d187fe','subnet-0e78f426f8938df2d','subnet-03edeaf52c46468fa','subnet-096fb5b3a7da814c2']";;
us-west-2_0) subnets="['subnet-04055d49cdf149e87','subnet-0b658a04c438ef43c','subnet-015f32caeff1bd736','subnet-0c96a7bb6ac78323c','subnet-0b7387e251953bdcf','subnet-0c19695d20ce05c60']";;
us-west-2_1) subnets="['subnet-0483607b3e3c2514f','subnet-01139c6c5e3c1e28e','subnet-0cc9500f56a1df779','subnet-001b2c8acd2bac389','subnet-093f66b9d6deffafc','subnet-095b373699fb51212']";;
us-west-2_2) subnets="['subnet-057c716b8953f834a','subnet-096f21593f10b44cb','subnet-0f281491881970222','subnet-0fec3730729e452d9','subnet-0381cfcc0183cb0ba','subnet-0f1189be41a2a2a2f']";;
us-west-2_3) subnets="['subnet-072d00dcf02ad90a6','subnet-0ad913e4bd6ff53fa','subnet-09f90e069238e4105','subnet-064ecb1b01098ff35','subnet-068d9cdd93c0c66e6','subnet-0b7d1a5a6ae1d9adf']";;
*) echo >&2 "invalid subnets index"; exit 1;;
esac
echo "Subnets : ${subnets}"

cat >> "${PATCH}" << EOF
platform:
  aws:
    subnets: ${subnets}
EOF

/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
