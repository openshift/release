# Red Hat JBoss Enterprise Application Platform OpenShift Tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
    - [Cluster Provisioning and Deprovisioning](#cluster-provisioning-and-de-provisioning)
    - [Test Setup, Execution, and Reporting Results](#test-setup-execution-and-reporting-results)

## General Information

- **Repository**: [jboss-eap-qe/openshift-eap-tests](https://github.com/jboss-eap-qe/openshift-eap-tests/)
- **Operator Tested**: [Red Hat JBoss Enterprise Application Platform](https://developers.redhat.com/products/eap/overview)
- **Maintainers**: EAP QE

Currently, [pit-7.4.x](https://github.com/jboss-eap-qe/openshift-eap-tests/tree/pit-7.4.x) tag is being used for the testing.

## Purpose

Execute a collection of tests for testing EAP images on OpenShift for both EAP 74 and XP streams. The results of these tests will be reported to the appropriate sources following execution.

## Process

EAP OpenShift testing scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS.
2. Create an image using [Dockerfile](https://github.com/jboss-eap-qe/openshift-eap-tests/blob/7.4.x/.ci/openshift-ci/build-root/Dockerfile).
3. Execute tests and archive results.
4. De-provision a test cluster.

### Cluster Provisioning and De-provisioning

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this
workflow. This workflow is not maintained by the Interop QE team and the EAP QE team.

### Test Setup, Execution, and Reporting Results

Following the test cluster being provisioned, the following steps are executed in this order:

1. Configure `test.properties` file with the test cluster connection setup properties, using test cluster's attributes.
2. For the EAP 74 stream run the maven command:

    ```bash
    mvn clean test -Dmaven.repo.local=./repo -P74-openjdk11,eap-pit-74 -Dxtf.operator.properties.skip.installation=true
    ```
    The command uses profile `74-openjdk11` for the image selection (EAP 7.4 with jdk11 image) and profile `eap-pit-74` to select tests to run.

    **NOTE:** `-Dxtf.operator.properties.skip.installation=true` prevents from installing the operator using the testsuite automation and allows the marketplace way to be used instead.


3. For the EAP XP stream run the maven command:

    ```bash
    mvn clean test -Dmaven.repo.local=./repo -Pxp4-openjdk11,eap-pit-xp -Dxtf.operator.properties.skip.installation=true -Dxtf.version=0.30-tar-dcihak-SNAPSHOT
    ```
    **NOTE:** `-Dxtf.version=0.30-tar-dcihak-SNAPSHOT` parameter is a workaround due to https://github.com/habitat-sh/builder/issues/365#issuecomment-382862233 and should be removed once the new xtf version will be released and integrated into the OpenShift testsuite.
    
    The command uses profile `xp4-openjdk11` for the image selection (defined by the property `xtf.eap.xp4-openjdk11.image` in the [global-test.properties](global-test.properties) file) and profile `eap-pit-xp` to select tests to run.
    
    Those tests are defined in the [xpTests.txt](test-eap%2FxpTests.txt) file.


4. Collect all Junit test outputs into Artifact dir, clean temporary tests-related files.
5. Report the test results into the both [JBEAP jira project](https://issues.redhat.com/projects/JBEAP/summary) and a public Slack channel `eap-ocp-ci-results`

