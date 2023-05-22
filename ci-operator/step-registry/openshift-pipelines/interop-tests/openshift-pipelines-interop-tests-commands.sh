#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

XML_PATH="/tmp/release-tests/reports/xml-report/result.xml"

echo "Running gauge specs parallely..."
gauge run --log-level=debug --verbose --tags sanity -p specs/clustertasks/ specs/pipelines/ specs/triggers/ specs/hub/ specs/metrics/ specs/pac/ specs/operator/addon.spec specs/operator/post-upgrade.spec specs/operator/pre-upgrade.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_parallel_specs.xml

echo "Running gauge specs serially..."
gauge run --log-level=debug --verbose --tags sanity specs/operator/auto-prune.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_auto_prune.xml

gauge run --log-level=debug --verbose --tags sanity specs/operator/rbac.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_rbac.xml
