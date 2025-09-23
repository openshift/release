#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

AWS_LOAD_BALANCER_OPERATOR_SRC_DIR="/go/src/github.com/openshift/aws-load-balancer-operator"
AWS_CREDENTIALS_REQUEST="${SHARED_DIR}/operator-credentials-request.yaml"
AWS_CONTROLLER_CREDENTIALS_REQUEST="${SHARED_DIR}/controller-credentials-request.yaml"

cp ${AWS_LOAD_BALANCER_OPERATOR_SRC_DIR}/hack/operator-credentials-request.yaml "${AWS_CREDENTIALS_REQUEST}"
cp ${AWS_LOAD_BALANCER_OPERATOR_SRC_DIR}/hack/controller/controller-credentials-request-minify.yaml "${AWS_CONTROLLER_CREDENTIALS_REQUEST}"

/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'metadata.namespace' openshift-cloud-credential-operator
/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'metadata.name' ${OPERATOR_CREDENTIALS_REQUEST}
/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'spec.secretRef.namespace' ${OO_INSTALL_NAMESPACE}
/tmp/yq w -i "${AWS_CREDENTIALS_REQUEST}" 'spec.secretRef.name' ${OPERATOR_SECRET}

if [ "${OO_APPLY_RESOURCES}" = "true" ]; then
    oc apply -f "${AWS_CREDENTIALS_REQUEST}"
    oc apply -f "${AWS_CONTROLLER_CREDENTIALS_REQUEST}"
fi
