#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function install_yq() {
    # Install yq manually if not found in image
      echo "Installing yq"
      mkdir -p /tmp/bin
      export PATH="/tmp/bin:${PATH}"
      curl -L "https://github.com/mikefarah/yq/releases/download/v4.52.4/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
       -o /tmp/bin/yq && chmod +x /tmp/bin/yq

      # Verify installation
      cmd_yq="$(/tmp/bin/yq --version 2>/dev/null || true)"
      if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
      else
        # Skip test mapping since yq isn't available
        export MAP_TESTS="false"
      fi
}

# Merge multiple jUnit XML files into one (avoids naming conflict with other Steps). Optionally map suite name for CR.
# Archives original XMLs so Prow does not see duplicated results.
function CleanupCollect() {
    typeset mergedFN="${1:-jUnit.xml}"; (($#)) && shift
    typeset resultFile=''
    typeset -a xmlFiles=()

    install_yq

    if [[ $MAP_TESTS == "false" ]]; then
        true
        return
    fi

    typeset mergedPath="${ARTIFACT_DIR%/}/${mergedFN}"
    while IFS= read -r -d '' resultFile; do
        grep -qE '<testsuites?\b' "${resultFile}" && xmlFiles+=("${resultFile}") || true
    done < <(find -L "${ARTIFACT_DIR%/}" -type f \( -iname "*.xml" -a -not -path "${mergedPath}" \) -print0)
    ((${#xmlFiles[@]})) || {
        : 'Warning: No JUnit XML file found to process'
        true
        return
    }

    # Prepare one jUnit XML: collect -> map suite name and merge into a single document
    yq eval-all --input-format xml --output-format xml -I2 '
        (. | [.[] | (.testsuite // .) | ([] + .)[] | select(kind == "map")]) as $suites |
        $suites | .[] |= (
            (
                select(env(MAP_TESTS) == "true") |
                ."+@name" = env(REPORTPORTAL_CMP)
            )//. |
            ([] + (.testcase // [])) as $tc |
            ."+@tests" = ($tc | length | tostring) |
            ."+@failures" = ([$tc[] | select(.failure)] | length | tostring) |
            ."+@errors" = ([$tc[] | select(.error)] | length | tostring)
        ) |
        {
            "+p_xml": "version=\"1.0\" encoding=\"UTF-8\"",
            "testsuites": {"testsuite": $suites}
        }
    ' "${xmlFiles[@]}" 1> "${ARTIFACT_DIR}/${mergedFN}"

    # Archive the original jUnit XMLs so Prow does not see duplicated results.
    tar zcf "${ARTIFACT_DIR}/jUnit-original.tgz" -C "${ARTIFACT_DIR}/" "${xmlFiles[@]#${ARTIFACT_DIR}/}"
    rm -f "${xmlFiles[@]}"

    cp "${ARTIFACT_DIR}/${mergedFN}" "${SHARED_DIR}/"
    true
}

# Post test execution
trap 'CleanupCollect junit--stackrox__qa-e2e__stackrox-qa-e2e.xml' EXIT

job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# this part is used for interop opp testing under stolostron/policy-collection
if [ ! -f ".openshift-ci/dispatch.sh" ];then
  if [ ! -d "stackrox" ];then
    git clone https://github.com/stackrox/stackrox.git
  fi
  cd stackrox || exit
fi

.openshift-ci/dispatch.sh "${job}"

