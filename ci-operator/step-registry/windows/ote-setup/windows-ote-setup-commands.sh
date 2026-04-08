#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

WMCO_NS="openshift-windows-machine-config-operator"

# OPERATOR_IMAGE is the WMCO CI image built from Dockerfile.ci, which includes
# wmco-tests-ext.gz at /usr/bin/wmco-tests-ext.gz
if [[ -z "${OPERATOR_IMAGE:-}" ]]; then
  echo "ERROR: OPERATOR_IMAGE is not set, cannot set up OTE"
  exit 1
fi

echo "Setting up WMCO OTE non-payload binary registration..."
echo "WMCO image: ${OPERATOR_IMAGE}"

# Create the WMCO namespace if it does not yet exist.
# WMCO may not be deployed at this point; we create the namespace so the
# ImageStream can be set up before the operator is installed.
oc create namespace "$WMCO_NS" --dry-run=client -o yaml | oc apply -f -

# Create ImageStream in the WMCO namespace
oc apply -n "$WMCO_NS" -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: wmco-ote
  namespace: ${WMCO_NS}
EOF

# Import the WMCO CI image as an ImageStreamTag.
# The CI image (Dockerfile.ci) contains /usr/bin/wmco-tests-ext.gz.
oc import-image wmco-ote:latest \
  -n "$WMCO_NS" \
  --from="${OPERATOR_IMAGE}" \
  --confirm

# Annotate the ImageStreamTag so openshift-tests can discover the OTE binary
oc annotate imagestreamtag wmco-ote:latest \
  -n "$WMCO_NS" \
  --overwrite \
  "testextension.redhat.io/component=windows-machine-config-operator" \
  "testextension.redhat.io/binary=/usr/bin/wmco-tests-ext.gz"

# Create TestExtensionAdmission CR permitting the WMCO namespace.
# Note: the TestExtensionAdmission CRD is installed by the
# openshift-tests-extension-admission-crd-install step in the workflow.
openshift-tests extension-admission create wmco \
  --permit="${WMCO_NS}/wmco-ote"

echo "OTE setup complete. WMCO test binary is now discoverable by openshift-tests."
