#!/bin/bash

# This script populates ConfigMaps using the templatesuration
# files in these directories. To be used to bootstrap the
# build cluster after a redeploy.

set -o errexit
set -o nounset
set -o pipefail

templates="$( dirname "${BASH_SOURCE[0]}" )/templates"

for templates_file in $( find "${templates}/" -mindepth 1 -type f -name "*.yaml" ); do
	template_name="$( basename "${templates_file}" ".yaml" )"
	oc create configmap "prow-job-${template_name}" "--from-file=${templates_file}" -o yaml --dry-run | oc apply -f -
done