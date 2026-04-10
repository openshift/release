#!/usr/bin/env bash
set -vx

RELEASE=4.8
ocp_upper_bound_tag="stable"

#for name in ocp-dev-preview/candidate ocp-dev-preview/latest ocp/candidate ocp/latest ocp/fast ocp/stable ; do
#  printf "%s\t" "${name}"
#  curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/${name}/release.txt \
#    | grep '^\(Name\|Created\):' | rev | cut -d' ' -f1 | rev | tr '\n' ' '
#  echo ""
#done 2>&1 | column -x -c 3 -t
ocp_stable=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt \
  | grep '^Name:' | rev | cut -d' ' -f1 | rev | cut -d\. -f1,2)
echo [${ocp_stable}]
if [ -z "${ocp_stable}" ]; then
  echo "Stable OCP upper-bound version not found. Please modify the files directly."
fi

if [[ ! -z "${ocp_stable}" ]]; then
  ocp_upper_bound_tag="${ocp_upper_bound_tag}-${ocp_stable}"
fi
BRANCH='stackrox-release-4.8'
CFG_DIR="ci-operator/config/stackrox/stackrox"
          # Duplicate the template configurations
          set -x
          ls -la "$CFG_DIR"
          for yaml in "$CFG_DIR"/stackrox-stackrox-release-x.y*.yaml ; do
            new_yaml="${yaml//stackrox-release-x.y/$BRANCH}"
            echo "Copying ${yaml} to ${new_yaml}"
            yq eval \
              ".zz_generated_metadata.branch=\"release-$RELEASE\"" \
              "$yaml" > "$new_yaml"
          done
          git status
          git add ci-operator/config/stackrox
          sed -i '' "s/OCP_VERSION: ocp\/candidate.*$/OCP_VERSION: ocp\/${ocp_upper_bound_tag}/" \
            "ci-operator/config/stackrox/stackrox/stackrox-${BRANCH}"*
          git diff
rm ci-operator/config/stackrox/stackrox/stackrox-${BRANCH}*.yaml
#git checkout "$CFG_DIR"
