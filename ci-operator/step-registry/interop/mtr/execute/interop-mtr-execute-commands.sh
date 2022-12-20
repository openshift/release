#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Define the variables needed to create the MTR test configuration file. The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"
APPS_URL=$(cat ${SHARED_DIR}/apps_url)
MTR_USERNAME=$(cat ${SECRETS_DIR}/mtr/mtr-username)
MTR_PASSWORD=$(cat ${SECRETS_DIR}/mtr/mtr-password)
FTP_USERNAME=$(cat ${SECRETS_DIR}/ftp/ftp-username)
FTP_PASSWORD=$(cat ${SECRETS_DIR}/ftp/ftp-password)
FTP_HOST=$(cat ${SECRETS_DIR}/ftp/ftp-host)
APP_HOSTNAME="http://${APPS_URL}"
OCP_HOSTNAME="http://mtr-mtr.${APPS_URL}/"
OCP_SECURE_HOSTNAME="https://secure-mtr-mtr.${APPS_URL}/"
SELENIUM_EXECUTOR=$(cat ${SHARED_DIR}/selenium-executor)

# Create the MTR test configuration file needed to execute the tests properly against the test cluster. 
# The file is created by replacing values in a pre-defined yaml file within the container using the `sed` command along with variables defined above.
echo "Replacing values in config file"
sed -i "s#REPLACE_HOSTNAME#${APP_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_OCP_HOSTNAME#${OCP_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_OCP_SECURE_HOSTNAME#${OCP_SECURE_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_HOST#${FTP_HOST}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_USERNAME#${FTP_USERNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_PASSWORD#${FTP_PASSWORD}#" $CONFIG_FILE
sed -i "s#REPLACE_EXECUTOR#${SELENIUM_EXECUTOR}#" $CONFIG_FILE
sed -i "s#REPLACE_MTR_PASSWORD#${MTR_PASSWORD}#" $CONFIG_FILE
sed -i "s#REPLACE_MTR_USER#${MTR_USERNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_MTR_VERSION#${MTR_VERSION}#" $CONFIG_FILE

# Install the MTR tests from the /tmp/integration_tests directory within the container. 
# These tests come from the the windup/windup_integration_test repository maintained by MTR product QE.
# These tests must be installed in this script rather than when the container image is built because OpenShift runs these containers using a user that ends up not having 
# access to modify the configuration file needed to execute these tests. Because that configuration file changes with every run, we have to modify it *then* install 
echo "Installing integration tests"
pip install -e /tmp/integration_tests

# Because these tests require an FTP server and the one used previously is behind our firewall, this image contains a script that will start a local FTP server that holds the `.war` needed to execute the tests. 
# The following command will start the server in the background.
echo "Starting the local FTP Server"
python /tmp/ftp_server.py &

# Execute the Interop MTR tests. The XUnit/JUnit results are then published to the `${SHARED_DIR}/xunit_output.xml` file. This file is to be used in the interop-mtr-report step of this scenario.
echo "Executing PyTest..."
pytest /tmp/integration_tests/mta/tests/operator/test_operator_test_cases.py -vv --reruns 4 --reruns-delay 10 --junitxml=${SHARED_DIR}/xunit_output.xml

# Stop the local FTP server that was started earlier in the script. If the process is left running, the execute pod will not complete and OpenShift CI will stop the pod after 2 hours, failing the execution.
echo "Shutting down the FTP server"
pkill -f ftp_server.py