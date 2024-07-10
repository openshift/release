#!/bin/bash
set -x
set -o errexit

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: dedicated-admin # live migration will only occur if the aforementioned namespace is present.
EOF
