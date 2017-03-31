#!/bin/bash

if [[ ! -f ~/.config/jenkins_jobs/jenkins_jobs.ini ]]; then
	export TOKEN="$(oc whoami -t)"
	mkdir -p ~/.config/jenkins_jobs
	cat ~/jenkins_jobs.ini.template | envsubst > ~/.config/jenkins_jobs/jenkins_jobs.ini
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
