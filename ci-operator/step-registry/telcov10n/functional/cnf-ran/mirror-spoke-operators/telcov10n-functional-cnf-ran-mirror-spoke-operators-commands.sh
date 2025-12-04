#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

cd /eco-ci-cd
ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "release=${VERSION} disconnected=true mirror_only=true operators='$OPERATORS'"

