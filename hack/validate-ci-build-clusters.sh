#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

base_dir="${1:-}"
kubeconfig_dir="${2:-}"
kubeconfig_suffix="${3:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a path to a directory with release repo layout"
  exit 1
fi

if [[ ! -d "${kubeconfig_dir}" ]]; then
  echo "Expected a path to a directory with valid kubeconfigs"
  exit 1
fi

if [[ "${kubeconfig_suffix}" == "" ]]; then
  echo "Expected kubeconfig suffix"
  exit 1
fi

releaserepo_workdir="${workdir}/release"
mkdir -p "$releaserepo_workdir"
cp -r "${base_dir}/"* "${releaserepo_workdir}"

cat >"${workdir}/cluster-install.yaml" <<EOF
onboard:
  releaseRepo: "$releaserepo_workdir"
  kubeconfigDir: "$kubeconfig_dir"
  kubeconfigSuffix: "$kubeconfig_suffix"
EOF

cluster-init onboard config generate \
    --cluster-install="${workdir}/cluster-install.yaml" \
    --create-pr=false \
    --update=true

declare -a files=(
              "/clusters/app.ci"
              "/clusters/build-clusters"
              "/ci-operator/jobs/openshift/release"
              "/core-services/ci-secret-bootstrap"
              "/core-services/ci-secret-generator"
              "/core-services/sanitize-prow-jobs"
              "/core-services/sync-rover-groups"
)
exitCode=0
for i in "${files[@]}"
do
  if ! diff -Naupr "${base_dir}$i" "${releaserepo_workdir}$i" > "${releaserepo_workdir}/diff"; then
    echo ERROR: The configuration in "$i" does not match the expected generated configuration, diff:
    cat "${releaserepo_workdir}/diff"
    exitCode=1
  fi
done

if [ "$exitCode" = 1 ]; then
  echo ERROR: Run the following command to update the build cluster configs:
  echo ERROR: $ make update-ci-build-clusters
fi

exit "$exitCode"
