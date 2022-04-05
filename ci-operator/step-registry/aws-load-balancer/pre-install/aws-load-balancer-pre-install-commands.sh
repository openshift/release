#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

AWS_LOAD_BALANCER_OPERATOR_SRC_DIR="/go/src/github.com/openshift/aws-load-balancer-operator"
AWS_CREDENTIALS_REQUEST="/tmp/operator-credentials-request.yaml"

cp ${AWS_LOAD_BALANCER_OPERATOR_SRC_DIR}/hack/operator-credentials-request.yaml "${AWS_CREDENTIALS_REQUEST}"

/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'metadata.namespace' openshift-cloud-credential-operator
/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'metadata.name' ${OO_PACKAGE}
/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'spec.secretRef.namespace' ${OO_INSTALL_NAMESPACE}
/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'spec.secretRef.name' ${OO_PACKAGE}

oc apply -f "${AWS_CREDENTIALS_REQUEST}"
