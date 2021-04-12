#!/bin/bash

# This script ensures that the generated configurations (e.g. prowjobs) checked into git are up-to-date
# with the generator. If they are not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

rcPaths=(
  "${base_dir}/core-services/release-controller"
  "${base_dir}/clusters/app.ci/release-controller"
  "${base_dir}/clusters/build-clusters/common/release-controller"
)

gather_rc_md5s() {
    find "${rcPaths[@]}" -type f -exec md5sum '{}' + | sort
}

PRE_RC_GEN=$(gather_rc_md5s)
${base_dir}/hack/generators/release-controllers/generate-release-controllers.py "${base_dir}"
POST_RC_GEN=$(gather_rc_md5s)

if [[ "${PRE_RC_GEN}" != "${POST_RC_GEN}" ]]; then
    cat << EOF
ERROR: This check enforces that Release Controller configuration files are generated
ERROR: correctly. We have automation in place that generates these configs and
ERROR: any changes must be included in your pull-request.

ERROR: Run the following command to re-generate the release controller configurations, run:
ERROR: $ make release-controllers

ERROR: The following differences were found:

EOF
    diff <(echo "$PRE_RC_GEN") <(echo "$POST_RC_GEN")
    exit 1
fi

# Call the validate-release-jobs script.  It will exit a non-zero value if/when there
# is a problem and a zero if everything checks out.
./hack/validate-release-jobs.py -r ${base_dir}

exit 0
