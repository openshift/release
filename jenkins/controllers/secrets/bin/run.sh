#!/bin/bash

# If Jenkins service not present, instantiate it
if ! oc get service jenkins; then
	oc new-app --template="${JENKINS_TEMPLATE_NAME}"
	while [[ $(oc get endpoints jenkins -o jsonpath='{ .subsets[*].addresses[0].ip }') == "" ]]; do
		sleep 1
	done
fi

oc observe secrets                                                     \
   --names=secret-names.py                                             \
   --delete=secret-delete.py                                           \
   -a "{ .metadata.annotations.ci\.openshift\.io/jenkins-secret-id }"  \
   -- secret-added.py
