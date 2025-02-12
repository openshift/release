#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit
echo "branch"
echo "PULL_BASE_REF : $PULL_BASE_REF"
BRANCH=$(jq -r '.refs.base_ref' <<< "$JOB_SPEC")
echo "Running tests on branch: $BRANCH"
BRANCH_NEW=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref')
echo "Running tests on BRANCH_NEW: $BRANCH_NEW"

sleep 600
