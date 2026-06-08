# mce-multi-version-test
https://issues.redhat.com/browse/OCPSTRAT-1650

## Table of Contents<!-- omit from toc -->
- [Purpose](#Purpose)
- [Process](#Process)
- [TODO](#TODO)

## Purpose
The step is used to automatically trigger all valid combinations of ACM HUB, MCE and Hosted Control Planes (HCP).

This step will cover AWS, Agent, KubeVirt, IBM Power and IBM Z in the future.

## Process
The script automates the process of:

+ Retrieve nightly release images from OpenShift CI.
+ Trigger CI jobs for the combination of ACM HUB, MCE and HCP versions.
    ```shell
    declare -A mce_to_guest=(
        #MCE   HCP
        [2.4]="4.14"
        [2.5]="4.14 4.15"
        [2.6]="4.14 4.15 4.16"
        [2.7]="4.14 4.15 4.16 4.17"
        [2.8]="4.14 4.15 4.16 4.17 4.18"
    )
    declare -A hub_to_mce=(
        #HUB    MCE
        [4.14]="2.4 2.5 2.6"
        [4.15]="2.5 2.6 2.7"
        [4.16]="2.6 2.7 2.8"
        [4.17]="2.7 2.8"
        [4.18]="2.8"
    )
    ```
+ Check the status of jobs into the ${SHARED_DIR}/job_list after they are triggered.
+ Generate a JUnit XML report for job status.

## TODO
+ Due to limitations of the Prow Gangway API, we are currently unable to retrieve the job URL. We need to find a workaround or modify the Gangway API.