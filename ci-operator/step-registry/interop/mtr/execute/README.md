# interop-mtr-execute-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
  - [Define Required Variables](#define-required-variables)
  - [Create MTR Test Configuration File](#create-mtr-test-configuration-file)
  - [Install MTR Tests](#install-mtr-tests)
  - [Start the local FTP Server](#start-the-local-ftp-server)
  - [Execute Tests](#execute-tests)
  - [Stop the local FTP Server](#stop-the-local-ftp-server)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)
  - [Credentials](#credentials)


## Purpose

To retrieve all of the required variables, use those variables to write a configuration file, install the Python MTR tests, and execute those tests against a test cluster using Selenium. The tests should produce valid XUnit results to be stored in the `SHARED_DIR` to be used by the [interop-mtr-report](../report/README.md) step. 

## Process

This script can be separated into 5 sections - Define required variables, create configuration file, install MTR tests, start the local FTP server, execute tests, and stop the local FTP server.

### Define Required Variables

The following code snippet is used to define the variables needed to [create the MTR test configuration file](#create-mtr-test-configuration-file). The variables defined in this step come from files in the `SHARED_DIR` and [credentials](#credentials) from Vault.

```bash
APPS_URL=$(cat ${SHARED_DIR}/apps_url)
FTP_USERNAME=$(cat ${SECRETS_DIR}/ftp-username)
FTP_PASSWORD=$(cat ${SECRETS_DIR}/ftp-password)
FTP_HOST=$(cat ${SECRETS_DIR}/ftp-host)
APP_HOSTNAME="http://${APPS_URL}"
OCP_HOSTNAME="http://mtr-mtr.${APPS_URL}/"
OCP_SECURE_HOSTNAME="https://secure-mtr-mtr.${APPS_URL}/"
SELENIUM_EXECUTOR=$(cat ${SHARED_DIR}/selenium-executor)
```

### Create MTR Test Configuration File

The following code snippet is used to create the MTR test configuration file needed to execute the tests properly against the test cluster. The file is created by replacing values in a [pre-defined yaml file within the container](https://github.com/calebevans/windup_integration_test/blob/mtr/dockerfiles/interop/env.yaml) using the `sed` command along with [variables](#define-required-variables) defined earlier in the script.

```bash
echo "Replacing values in config file"
sed -i "s#REPLACE_HOSTNAME#${APP_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_OCP_HOSTNAME#${OCP_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_OCP_SECURE_HOSTNAME#${OCP_SECURE_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_HOST#${FTP_HOST}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_USERNAME#${FTP_USERNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_PASSWORD#${FTP_PASSWORD}#" $CONFIG_FILE
sed -i "s#REPLACE_EXECUTOR#${SELENIUM_EXECUTOR}#" $CONFIG_FILE
```

### Install MTR Tests

The following code snippet uses `pip` to install the MTR tests from the `/tmp/integration_tests` directory within the container. These tests come from the the [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git) repository maintained by MTR product QE. These tests must be installed in this script rather than when the container image is built because OpenShift runs these containers using a user that ends up not having access to [modify the configuration file](#create-mtr-test-configuration-file) needed to execute these tests. Because that configuration file changes with every run, we have to modify it *then* install the tests.

```bash
echo "Installing integration tests"
pip install -e /tmp/integration_tests
```

### Start the local FTP Server

Because these tests require an FTP server and the one used previously is behind our firewall, this image contains a script that will start a local FTP server that holds the `.war` needed to execute the tests. The following command will start the server and save the PID of the FTP server process to the `/tmp/ftp_pid` file. This file will be used to stop the FTP server later.

```bash
echo "Starting the local FTP Server"
nohup python /tmp/ftp_server.py &
echo $! > /tmp/ftp_pid
```

### Execute Tests

The following code snippet uses `pytest` to execute the Interop MTR tests. The XUnit/JUnit results are then published to the `${SHARED_DIR}/xunit_output.xml` file. This file is to be used in the [interop-mtr-report](../report/README.md) step of this scenario.

```bash
echo "Executing PyTest..."
pytest /tmp/integration_tests/mta/tests/operator/test_operator_test_cases.py -vv --reruns 4 --reruns-delay 10 --junitxml=${SHARED_DIR}/xunit_output.xml
```

### Stop the local FTP Server

The following line of code will stop the local FTP server that was started earlier in the script. If the process is left running, the execute pod will not complete and OpenShift CI will stop the pod after 2 hours, failing the execution.

```bash
kill -9 `cat /tmp/ftp_pid`
```

## Container Used

The container used in this step is named `mtr-runner` in the [configuration file](../../../../config/calebevans/calebevans-windup_integration_test-mtr.yaml). This container created from a custom image located in the [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git) repository within in the `dockerfiles/interop` directory. The code snippet below is the Dockerfile found in that repository.

```Dockerfile
FROM python:3.8

# Update and install FTP
RUN apt -y update && apt -y install ftp

# Upgrade pip and install required packages
RUN pip install --upgrade pip
RUN pip install pytest importscan pyftpdlib

# Copy the windup_integration_test repo into /tmp/integration_tests
RUN mkdir /tmp/integration_tests
WORKDIR /tmp/integration_tests
COPY . .

# Add interop env file to mta/conf/env.yaml
COPY dockerfiles/interop/src/env.yaml mta/conf/env.yaml

# Create the /ftpuser directory
RUN mkdir -p /home/ftpuser/mtr/applications

# Add WAR file for testing
COPY dockerfiles/interop/src/acmeair-webapp-1.0-SNAPSHOT.war /home/ftpuser/mtr/applications/acmeair-webapp-1.0-SNAPSHOT.war

# Add ftp_server.py script
COPY dockerfiles/interop/src/ftp_server.py /tmp/ftp_server.py

# Set required permissions for OpenShift usage
RUN chgrp -R 0 /tmp && \
    chmod -R g=u /tmp

RUN chgrp -R 0 /home && \
    chmod -R g=u /home

CMD ["/bin/bash"]
```

## Requirements

### Variables

- `CONFIG_FILE`
  - **Definition**: The path to the config file required for MTR test execution.
  - **If left empty**: The default value for this path is `/tmp/integration_tests/mta/conf/env.yaml` and **generally should not change**. This variable is here just in case it needs to be overridden in the future.

### Infrastructure

- A provisioned test cluster to target.
- A Selenium container running in the test cluster that allows for ingress
  - This is taken care of in the [interop-mtr-orchestrate](../orchestrate/README.md) -> [interop-tooling-deploy-selenium](../../tooling/deploy-selenium/README.md) step

### Credentials

- `mtr-ftp-credentials`
  - **Collection**: [mtr-qe](https://vault.ci.openshift.org/ui/vault/secrets/kv/ddlist/selfservice/mtr-qe/)
  - **Usage**: Used to retrieve required files from the FTP server during test execution