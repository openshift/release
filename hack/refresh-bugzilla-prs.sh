#!/bin/bash

# This script refresh bugzilla PRs
# Required in branch cutting
TMPDIR="${TMPDIR:-/tmp}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
BRANCHES=(main master)

echo Fetching oauth token...
mkdir -p /TMPDIR/refresh-bugzilla-prs
oc get secret --context app.ci github-credentials-openshift-bot -o json | jq -r .data.oauth | base64 --decode > $TMPDIR/refresh-bugzilla-prs/oauth

echo Commenting...
$CONTAINER_ENGINE pull gcr.io/k8s-prow/commenter:latest
for branch in "${BRANCHES[@]}"
do
    $CONTAINER_ENGINE run --platform linux/amd64 --rm -v $TMPDIR/refresh-bugzilla-prs:/etc/oauth:ro gcr.io/k8s-prow/commenter:latest --query="is:pr comments:<2500 state:open base:${branch} label:bugzilla/valid-bug label:lgtm label:approved -label:needs-rebase" --token=/etc/oauth/oauth --updated=0 --ceiling=0 --comment=/bugzilla refresh "The requirements for Bugzilla bugs have changed (BZs linked to PRs on master branch need to target OCP 4.11), recalculating validity."
done

echo Cleaning up...
rm -r $TMPDIR/refresh-bugzilla-prs
