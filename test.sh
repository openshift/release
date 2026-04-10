#!/usr/bin/env bash

set -x

flavor=rosa
tag=latest

cd ~/dev/stack/openshift-release/

          test_names=''
          for test_file in ci-operator/config/stackrox/stackrox/stackrox-stackrox-master*.yaml; do
            sed -i$'' -e "s/tag: ${flavor}-stable/tag: ${flavor}-${tag}/" "$test_file"
            # TODO: if no match, continue
            # if ! $sed_exit_code; then continue; fi
            presubmit_file="ci-operator/jobs${test_file##ci-operator/config}"
            presubmit_file="${presubmit_file%%.yaml}-presubmits.yaml"
            test_names_tmp=$(grep -h -o "^ *name: [^ ]*-${flavor}.*" "$presubmit_file")
            test_names+=${test_names_tmp## *name:}
          done

          echo "/pj-rehearse $test_names" \


      #    git add $test_files
      #    git commit -m "stackrox: mirror automation-flavor ${{inputs.flavor}}-${{inputs.tag}}" >> "$GITHUB_STEP_SUMMARY"

          #PR_URL=$(gh pr create --repo openshift/release \
          #  --title "stackrox: mirror automation-flavor ${{inputs.flavor}}-${{inputs.tag}}" \
          #  --base "master" \
          #  --body "/cc ${GITHUB_ACTOR}")

          #gh pr comment "/pj-rehearse ${test_names}"
