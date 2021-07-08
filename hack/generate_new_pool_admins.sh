#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    >&2 echo "Illegal number of parameters"
    >&2 echo "$0 <team> <owners_seperated_with_comma>"
    >&2 echo "E.g., $0 cvp dmace,petr"
    exit 1
fi


TEAM=$1
OWNERS=$2

function val_from_python {
    # Get a python value from BASH.
    pythonval="$(python3 - <<END
import json
arg='$OWNERS'
l = arg.split(",")
# double quote the elements in l
print(json.dumps(l))
END
)"
}
val_from_python
OWNERS_PARAM=$pythonval


OUTPUT_DIR="clusters/hive/pools/$TEAM"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_FILE="${OUTPUT_DIR}/admins_${TEAM}-cluster-pool_rbac.yaml"
oc process -f clusters/hive/pools/_pool-admin-rbac_template.yaml -p TEAM=${TEAM} -p POOL_NAMESPACE=${TEAM}-cluster-pool -p "OWNERS=${OWNERS_PARAM}" -o yaml > "${OUTPUT_FILE}"
