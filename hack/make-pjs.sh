#!/bin/bash
# Author: Danilo Gemoli <dgemoli@redhat.com>
# Generates ProwJobs, mainly for tests on build clusters
# Usage:
# RELEASE_REPO=<...> \
# CLUSTER=build99 \
# HOW_MANY=5 \
# PROWJOBS_CONFIG='ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml' \
# TYPE=e2e \
# make_pjs.sh
#
# config for e2e: ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml
# config for intranet: ci-operator/config/openshift/release/openshift-release-main__nightly-4.19.yaml'

set -o errexit
set -o nounset
set -o pipefail

ORG=""
REPO=""
BRANCH=""
VARIANT=""
ARCH="${ARCH:-amd64}"

# Get the SHA of a branch
function branch_info() {
  git ls-remote "https://github.com/${ORG}/${REPO}" "$BRANCH"
}

# Generate PJs manifests and save them in a temporary directory /tmp/tests-XXXXX
function make_prowjobs() {
  tests=$1

  base_dir=$(mktemp -p /tmp -d 'tests-XXXXX')

  mkpj_img=$(awk -F '=' '/mkpj/{print $2}' "${RELEASE_REPO}/hack/images.sh")
  base_sha=$(branch_info | awk '{print $1}')
  echo "base_sha: $base_sha"

  for test in $tests; do
      echo "generating: ${base_dir}/${test}.yaml"
      refs=''
      if [[ $test != periodic* ]]; then
        refs='.spec.refs.pulls = [{
                  author: "fake",
                  number: 1,
                  sha: (.spec.refs.base_sha)
              }] |'
      fi
      podman run \
          --platform "linux/$ARCH" \
          --rm \
          --volume "$RELEASE_REPO:/tmp/release:z" \
          --workdir /tmp/release \
          "$mkpj_img" \
          --config-path core-services/prow/02_config/_config.yaml \
          --job-config-path ci-operator/jobs/ \
          --base-ref "$BRANCH" \
          --base-sha "$base_sha" \
          --pull-number 1 \
          --job "$test" \
          2>/dev/null \
          | yq -ojson \
          | jq "${refs:-}
              .status.state = \"triggered\"
              | .spec.report = false
              | .spec.cluster = \"$CLUSTER\"" \
          | yq -P \
          >"${base_dir}/${test}.yaml"
  done

  echo "output dir: $base_dir"
}

# Filter tests that have: `restrict_network_access: false`
function vpn_tests() {
  ci_operator_config="$1"

  variant=$(yq -ojson "${RELEASE_REPO}/${ci_operator_config}" \
            | jq -r '.zz_generated_metadata
                  | if has("variant") then .variant else "" end')

  names=$(yq -ojson "${RELEASE_REPO}/${ci_operator_config}" \
          | jq -jc \
              '[
                  .tests[]
                  | select(has("restrict_network_access") and (.restrict_network_access|not))
                  | .as
              ]')

  yq -ojson "${RELEASE_REPO}/ci-operator/jobs/${ORG}/${REPO}/${ORG}-${REPO}-${BRANCH}-"*.yaml \
  | jq -sr --arg variant "$variant" --argjson suffixes "$names" \
      ' .[]
      | if has("periodics") then .[][] else .[][][] end
      | if $variant == "" then
          .
        else
          select(.labels.["ci-operator.openshift.io/variant"]? == $variant)
        end
      | .name
      | . as $name
      | select(any($suffixes[]; . as $suffix|$name|endswith($suffix)))'
}

# Filter PJs whose name contains '-e2e-'
function e2e_tests() {
   prowjobs_config="$1"
   yq -ojson "${RELEASE_REPO}/${prowjobs_config}" \
   | jq -r --arg orgrepo "${ORG}/${REPO}" \
       'if has("periodics") then .[][] else .[][$orgrepo][] end
       | select(.name|contains("-e2e-"))
       | .name'
}

# Extract organization, repository, branch and variant from a path that matches the pattern:
#   ci-operator/config/${ORG}/${REPO}/${ORG}-${REPO}-${BRANCH}__${VARIANT}.yaml
function extract_test_info_from_config() {
   path="$1"

   ORG=$(awk -F '/' '{print $3}' <<<"$path")
   [ -z "$ORG" ] && echo "can't extract organization" && exit 1

   REPO=$(awk -F '/' '{print $4}' <<<"$path")
   [ -z "$REPO" ] && echo "can't extract repository" && exit 1

   filename=$(basename "$path")

   BRANCH=$(sed -E "s/${ORG}\-${REPO}\-([^_]+)(__.+)?\.yaml/\1/" <<<"$filename")
   [ -z "$BRANCH" ] && echo "can't extract branch" && exit 1

   VARIANT=$(sed -E "s/${ORG}\-${REPO}\-${BRANCH}(__(.+))?\.yaml/\2/" <<<"$filename")

   return 0
}

# Extract organization, repository and branch from a path that matches the pattern:
#   ci-operator/jobs/${ORG}/${REPO}/${ORG}-${REPO}-${BRANCH}-(presubmits|postsubmits|periodics).yaml
function extract_test_info_from_job() {
   path="$1"

   ORG=$(awk -F '/' '{print $3}' <<<"$path")
   [ -z "$ORG" ] && echo "can't extract organization" && exit 1

   REPO=$(awk -F '/' '{print $4}' <<<"$path")
   [ -z "$REPO" ] && echo "can't extract repository" && exit 1

   filename=$(basename "$path")

   BRANCH=$(sed -E "s/${ORG}\-${REPO}\-(.+)\-(presubmits|postsubmits|periodics)\.yaml/\1/" <<<"$filename")
   [ -z "$BRANCH" ] && echo "can't extract branch" && exit 1

   return 0
}

function dump_test_info() {
   echo "org: $ORG"
   echo "repo: $REPO"
   echo "branch: $BRANCH"
   echo "variant: $VARIANT"
}

function entrypoint() {
  [ -z "${RELEASE_REPO:-}" ] && echo "RELEASE_REPO is required" && exit 1
  [ -z "${CLUSTER:-}" ] && echo "CLUSTER is required" && exit 1
  [ -z "${HOW_MANY:-}" ] && echo "HOW_MANY is required" && exit 1
  [ -z "${TYPE:-}" ] && echo "TYPE is required" && exit 1

  case "$TYPE" in
      "e2e")
           PROWJOBS_CONFIG="${PROWJOBS_CONFIG:-ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml}"
           extract_test_info_from_job "$PROWJOBS_CONFIG"
           dump_test_info
           tests=$(e2e_tests "$PROWJOBS_CONFIG" | sort -R)
           [ -z "$tests" ] && echo "no e2e tests found in ${RELEASE_REPO}/${PROWJOBS_CONFIG}" && exit 1
           top_n=$(head -n "$HOW_MANY" <<<"$tests")
           make_prowjobs "$top_n"
          ;;
      "intranet")
           CI_OPERATOR_CONFIG="${CI_OPERATOR_CONFIG:-ci-operator/config/openshift/release/openshift-release-master__nightly-4.19.yaml}"
           extract_test_info_from_config "$CI_OPERATOR_CONFIG"
           dump_test_info
           tests=$(vpn_tests "$CI_OPERATOR_CONFIG" | sort -R)
           [ -z "$tests" ] && echo "no vpn tests found in ${RELEASE_REPO}/${CI_OPERATOR_CONFIG}" && exit 1
           top_n=$(head -n "$HOW_MANY" <<<"$tests")
           make_prowjobs "$top_n"
          ;;
      *)
          echo "unknown test type $TYPE"
          exit 1
          ;;
  esac
}

entrypoint
