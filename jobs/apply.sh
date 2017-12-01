#!/bin/bash

function generate_configmap() {
	local jenkinsfile="$1"
	local repo_owner="$2"
	local branch="$3"

	local name="${jenkinsfile%%.groovy}"
	local configmap_name="${name//\//-}-job"

	{
		cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${configmap_name}
  labels:
    created-by-ci: "true"
  annotations:
    ci.openshift.io/jenkins-job: "true"
data:
  job.yml: |-
    - job:
        name: ${name}
        project-type: pipeline
        concurrent: true
        properties:
          - build-discarder:
              days-to-keep: 1
        parameters:
          - string:
              name: BUILD_ID
              default: ""
              description: The ID that prow sets on a Jenkins job in order to correlate it with a ProwJob
          - string:
              name: JOB_SPEC
              default: ""
              description: Serialized build specification
          - string:
              name: REPO_OWNER
              default: ""
              description: Repository organization
          - string:
              name: REPO_NAME
              default: ""
              description: Repository name
          - string:
              name: PULL_BASE_REF
              default: ""
              description: Base branch
          - string:
              name: PULL_BASE_SHA
              default: ""
              description: Base branch commit
          - string:
              name: PULL_REFS
              default: ""
              description: Reference to build or test
          - string:
              name: PULL_NUMBER
              default: ""
              description: PR number
          - string:
              name: PULL_PULL_SHA
              default: ""
              description: PR HEAD commit
        pipeline-scm:
          script-path: jobs/${jenkinsfile}
          scm:
             - git:
                 url: https://github.com/${repo_owner}/release.git
                 branches:
                   - ${branch}
EOF
	} | oc apply -f -
}

function generate_folder() {
	local folder="$1"
	local configmap_name="${folder//\//-}-folder"

	{
		cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${configmap_name}
  labels:
    created-by-ci: "true"
  annotations:
    ci.openshift.io/jenkins-job: "true"
data:
  job.yml: |-
    - job:
        name: ${folder}
        project-type: folder
EOF
	} | oc apply -f -
}

repo_owner="${REPO_OWNER:-openshift}"
branch="${BRANCH:-master}"

for folder in $( find "$( dirname "${BASH_SOURCE[0]}")/" -mindepth 1 -type d ); do
  generate_folder "${folder#*jobs/}"
done

for jenkinsfile in $( find "$( dirname "${BASH_SOURCE[0]}")/" -type f -name \*.groovy ); do
  generate_configmap "${jenkinsfile#*jobs/}" "${repo_owner}" "${branch}" &
done

for job in $( jobs -p ); do
	wait "${job}"
done