#!/bin/bash

set -ex

echo 'HUB=4.14,  MCE=2.6,  HostedCluster=4.14,  PLATFORM=aws,  JOB=periodic-ci-openshift-hypershift-release-4.14-periodics-mce-e2e-aws-critical, JOB_ID=bc5e6337-adc0-4171-88b0-eaa66f498b37, JOB_STATUS=SUCCESS
HUB=4.14,  MCE=2.6,  HostedCluster=4.15,  PLATFORM=aws,  JOB=periodic-ci-openshift-hypershift-release-4.15-periodics-mce-e2e-aws-critical, JOB_ID=59f36e9d-ebe9-4322-a257-e8b0017904de, JOB_STATUS=FAILURE
HUB=4.14,  MCE=2.6,  HostedCluster=4.16,  PLATFORM=aws,  JOB=periodic-ci-openshift-hypershift-release-4.16-periodics-mce-e2e-aws-criticadddgl, JOB_ID=, JOB_STATUS=TriggerFailed
HUB=4.15,  MCE=2.5,  HostedCluster=4.14,  PLATFORM=aws,  JOB=periodic-ci-openshift-hypershift-release-4.14-periodics-mce-e2e-aws-critical, JOB_ID=67bab497-6900-4b23-be53-b5eaaa529334, JOB_STATUS=SUCCESS
HUB=4.15,  MCE=2.5,  HostedCluster=4.15,  PLATFORM=aws,  JOB=periodic-ci-openshift-hypershift-release-4.15-periodics-mce-e2e-aws-critical, JOB_ID=9acc8c33-d590-4cfd-abe4-58a720882adc, JOB_STATUS=SUCCESS' > "${SHARED_DIR}/job_list"
