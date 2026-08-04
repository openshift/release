# Troubleshooting olm deployment failures

This document should help you to analyze where to look in case that olm deployment has failed. It also describes workflows and which one should be your main concern. Logs location is also mentioned as one of the main subjects.
* [Workflows](#Workflows):
* [Logs and how to get them](#Logs-and-how-to-get-to-them):

## Workflows:
You can find all the workflows that are being executed in following yaml files:
https://github.com/openshift/release/tree/master/ci-operator/config/redhat-openshift-ecosystem/cvp

This example uses the `4.7` ocp version:
The workflow that interests you most is: **optional-operators-cvp-common-aws**.

*Env variables* together with *dependenciy_overrides* are specified before the workflow, these are used during the steps which are mentioned in workflow itself.
`CVP-COMMON-AWS` workflow does following: installs an optional operator using the input index image, package and channel and executes a common suite of CVP tests to validate the optional operator.

In case you want to know what individual step does, search for them in https://github.com/openshift/release/tree/master/ci-operator/step-registry/optional-operators


## Logs and how to get to them:
If there is a problem with olm deployment in cvp product jenkins pipeline, specifically in the *bundle-image-validation* job, such an issue will be recorded to corresponding prow job.
Whose link is going to look like this: 
https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-redhat-openshift-ecosystem-cvp-ocp-4.7-cvp-common-aws/"unique-number".

In this prow job you can inspect what exactly went wrong, which part of the workflow failed, etc.

The steps to investigate the issue are as follows:

**Step 1**: Go to the link of corresponding prow job and look at the **Build log** section.

**Step 2**: In case that it is unsure what the cause might be, proceed to artifacts at the top right section. 

**Step 3**: There should be a folder named `cvp-common-aws` under which are all steps in the workflow itself together with some other folders like `gather-extra`, `gather-must-gather` etc. , you can check *optional-operators-** folders one by one and check for **build-log.txt** and **finished.json** to see what happened.

**Step 4**: In case of message like "Timed out waiting for the catalog source <catalogsource name> to become ready after 10 minutes." We can assume that there is a problem initializing catalogsource timeout. Check the Operator index.

**Step 5**: If the issue is still unclear, you need to go to *artifacts/cvp-common-aws/gather-must-gather/artifacts/event-filter.html*. Try to search for words in messages like “Failed”, “Error” or the one that you found in the first **build-log.txt** file.
Individual parts of the workflow can be found in the artifacts folder. There is also a folder that contains events for the whole process : *artifacts/cvp-common-aws/gather-extra/artifacts/*, you can search here in advance to see what went wrong.
