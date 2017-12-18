#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

file=$1

if ! token=$( oc sa get-token prometheus-reader ); then
  oc create serviceaccount prometheus-reader
  oc policy add-role-to-user view -z prometheus-reader
  token=$( oc sa get-token prometheus-reader )
fi

echo "${token}" > "token-${file}"