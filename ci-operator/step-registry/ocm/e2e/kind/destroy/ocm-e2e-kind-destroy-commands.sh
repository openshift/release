#!/bin/bash

cd "${SHARED_DIR}/kind" || exit 1

terraform destroy -auto-approve
