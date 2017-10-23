#!/bin/bash

set -e

base=$( dirname "${BASH_SOURCE[0]}")

jenkins_host="$(oc get route jenkins -o jsonpath='{ .spec.host }')"
token="$(oc whoami -t)"
jenkins_url="https://${jenkins_host}"

files="$(find ${base}/.. -name Jenkinsfile)"
for file in ${files}; do
	echo "Validating ${file}"
	curl -k -X POST -H "Authorization: Bearer ${token}" -F "jenkinsfile=<${file}" "${jenkins_url}/pipeline-model-converter/validate"
done
