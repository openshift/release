#!/bin/bash

set -o nounset
set -o pipefail	

if [ $# -lt 1 ]; then
  echo 'Usage: find-job.sh <jobname>'
  exit 1
fi

function indent() {
  I=$1
  while [ 0 -ne $I ]; do
    echo -en "\t"
    I=$(($I - 1))
  done
}

function search_ref() {
  indent $3
  echo "$1: $2"
  test `head -n1 $2` == 'ref:' && return
  for REF in `grep -Eo '\s+-.*' $2 | sed -E 's/- | //g'`; do
    TYPE=`echo $REF | cut -d: -f1`
    NAME=`echo $REF | cut -d: -f2`
    YAML=`grep -r "as: $NAME$" ci-operator/step-registry/ | cut -d: -f1 | grep "$TYPE.yaml"`
    search_ref $NAME $YAML $(($3 + 1))
  done
}

YAML=`grep -r "as: $1$" ci-operator/step-registry/ | cut -d: -f1`
if [ -z $YAML ]; then
  echo "Job $1 not found"
  exit 1
fi

search_ref $1 $YAML 0
