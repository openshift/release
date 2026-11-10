#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOCALPATH="${SHARED_DIR}/manifest_external.yaml"
echo "${EXTERNAL_MANIFESTS_SHA256_HASH} -" > /tmp/sum.txt
if ! curl -fLs "${EXTERNAL_MANIFESTS_URL}" | tee "${LOCALPATH}" | sha256sum -c /tmp/sum.txt >/dev/null 2>/dev/null; then
  echo "Expected file at ${EXTERNAL_MANIFESTS_URL} to have checksum ${EXTERNAL_MANIFESTS_SHA256_HASH} but instead got $(< "${LOCALPATH}" sha256sum | cut -d' ' -f1)"
  exit 1
fi
echo "Downloaded ${EXTERNAL_MANIFESTS_URL}, sha256 checksum matches ${EXTERNAL_MANIFESTS_SHA256_HASH}"

# Check file syntax
pip3 install pyyaml==6.0 --user
python3 -c 'import yaml
import sys
data = yaml.safe_load_all(open(sys.argv[1]))' "${LOCALPATH}"

if [ "${EXTERNAL_MANIFESTS_POST_INSTALL}" == "true" ]; then
  oc apply -f "${LOCALPATH}"
  # Remove file to avoid filling up SHARED_DIR
  rm -rf "${LOCALPATH}"
else
  # If document contains multidoc yaml it needs to be split into separate manifests
  python3 -c 'import yaml;
import sys
import os

localpath = sys.argv[1]
try:
  with open(localpath, "r") as stream:
    data = list(yaml.load_all(stream, Loader=yaml.FullLoader))
    if len(data) == 1:
      sys.exit(0)
    filename, file_extension = os.path.splitext(localpath)
    for index, workload in enumerate(data, start=1):
      new_doc_path = f"{filename}_{index}.yaml"
      with open(new_doc_path, "a") as outfile:
        yaml.dump(workload, outfile)
        print(f"Created {new_doc_path}")
  os.remove(localpath)
except yaml.YAMLError as out:
  print(out)' "${LOCALPATH}"
fi
