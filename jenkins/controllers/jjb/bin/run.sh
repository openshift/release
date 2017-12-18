#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f ~/.config/jenkins_jobs/jenkins_jobs.ini ]]; then
	TOKEN="$(oc whoami -t)"
	export TOKEN
	mkdir -p ~/.config/jenkins_jobs
	sed "s/TOKEN/${TOKEN}/" ~/jenkins_jobs.ini.template > ~/.config/jenkins_jobs/jenkins_jobs.ini
fi

# If Jenkins service not present, instantiate it
if ! oc get service jenkins; then
	oc new-app --template="${JENKINS_TEMPLATE_NAME}"
	while [[ $(oc get endpoints jenkins -o jsonpath='{ .subsets[*].addresses[0].ip }') == "" ]]; do
		sleep 1
	done
fi

oc observe configmaps                                           \
   --names=job-list.py                                          \
   --delete=job-delete.py                                       \
   -a "{ .metadata.annotations.ci\.openshift\.io/jenkins-job }" \
   -- job-update.py
