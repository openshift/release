#!/bin/bash

# This script ensures that all component config files are accompanied by OWNERS file

#!/bin/bash
set -euo pipefail

WHITELIST=$(sort <<'EOF'
ci-operator/config/openshift/kubernetes-metrics-server
ci-operator/jobs/openshift/kubernetes-metrics-server
ci-operator/config/openshift/origin-metrics
ci-operator/jobs/openshift/origin-metrics
ci-operator/config/openshift/origin-web-console
ci-operator/jobs/openshift/origin-web-console
ci-operator/config/openshift/origin-web-console-server
ci-operator/jobs/openshift/origin-web-console-server
ci-operator/jobs/openvswitch/ovn-kubernetes
EOF
)

no_owners=$(find ci-operator/config/ ci-operator/jobs/ -mindepth 2 -type d ! -exec test -e '{}/OWNERS' \; -print | sort)
false_neg=$(comm -13 <(echo "$WHITELIST") <(echo "$no_owners"))
false_pos=$(comm -23 <(echo "$WHITELIST") <(echo "$no_owners"))

if [[ "$false_neg" ]]; then
  cat << EOF
ERROR: This check enforces that component configuration files are accompanied by OWNERS
ERROR: files so that the appropriate team is able to self-service further configuration
ERROR: change pull requests.

ERROR: Please copy and paste the OWNERS files from the component repositories.

ERROR: If the target repository does not contain an OWNERS file, it will need to be created manually.
ERROR: See https://github.com/kubernetes/community/blob/master/contributors/guide/owners.md for details.

ERROR: The following component config directories do not have OWNERS files:

$false_neg

EOF
fi


if [[ "$false_pos" ]]; then
  cat << EOF
ERROR: Directory that was previously whitelisted as not containing
ERROR: an OWNERS file is now containing the file, so it no longer
ERROR: needs to be whitelisted. Please remove the appropriate line
ERROR: from hack/validate-owners.sh script.

ERROR: Directories to be removed from whitelist:

$false_pos
EOF
fi

[[ ! "$false_neg" &&  ! "$false_pos" ]]
