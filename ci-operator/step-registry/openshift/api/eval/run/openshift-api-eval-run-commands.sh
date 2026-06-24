#!/bin/bash
set -euo pipefail

echo "=== OpenShift API Review Eval ==="

echo "Cloning openshift/api..."
git clone https://github.com/openshift/api.git /tmp/api
cd /tmp/api

if [ -n "${PULL_NUMBER:-}" ]; then
  echo "Presubmit: checking out PR #${PULL_NUMBER}..."
  git fetch origin "pull/${PULL_NUMBER}/head:pr-${PULL_NUMBER}"
  git checkout "pr-${PULL_NUMBER}"
else
  echo "Periodic: running against master"
fi

echo "Running eval suite (EVAL_RUNS=${EVAL_RUNS}, EVAL_THRESHOLD=${EVAL_THRESHOLD})..."
make eval-golden || rc=$?
make eval-integration || rc=$?

if [ -d "${ARTIFACT_DIR:-}" ]; then
  for f in tests/junit-eval-*.xml; do
    [ -f "$f" ] || continue
    python3 -c "
import xml.etree.ElementTree as ET, sys
tree = ET.parse(sys.argv[1])
for parent in tree.iter():
    for tc in list(parent):
        if tc.tag == 'testcase' and tc.find('skipped') is not None:
            parent.remove(tc)
tree.write(sys.argv[2], xml_declaration=True, encoding='UTF-8')
" "$f" "${ARTIFACT_DIR}/$(basename "$f")"
  done
fi

exit "${rc:-0}"
