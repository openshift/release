#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set variables used to update the config file
SECRETS_DIR="/tmp/secrets"
APPS_URL=$(cat ${SHARED_DIR}/apps_url)
FTP_USERNAME=$(cat ${SECRETS_DIR}/ftp-username)
FTP_PASSWORD=$(cat ${SECRETS_DIR}/ftp-password)
FTP_HOST=$(cat ${SECRETS_DIR}/ftp-host)
APP_HOSTNAME="http://${APPS_URL}"
OCP_HOSTNAME="http://mtr-mtr.${APPS_URL}/"
OCP_SECURE_HOSTNAME="https://secure-mtr-mtr.${APPS_URL}/"
SELENIUM_EXECUTOR=$(cat ${SHARED_DIR}/selenium-executor)

# Replace values in config
echo "Replacing values in config file"
sed -i "s#REPLACE_HOSTNAME#${APP_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_OCP_HOSTNAME#${OCP_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_OCP_SECURE_HOSTNAME#${OCP_SECURE_HOSTNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_HOST#${FTP_HOST}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_USERNAME#${FTP_USERNAME}#" $CONFIG_FILE
sed -i "s#REPLACE_FTP_PASSWORD#${FTP_PASSWORD}#" $CONFIG_FILE
sed -i "s#REPLACE_EXECUTOR#${SELENIUM_EXECUTOR}#" $CONFIG_FILE

# Install tests
echo "Installing integration tests"
pip install -e /tmp/integration_tests

# Start FTP Server
echo "Starting the local FTP Server"
nohup python /tmp/ftp_server.py &
# Save the PID of the FTP server process
FTP_SERVER_PID=$(echo $!)

# Execute tests
echo "Executing PyTest..."
pytest /tmp/integration_tests/mta/tests/operator/test_operator_test_cases.py -vv --reruns 4 --reruns-delay 10 --junitxml=${SHARED_DIR}/xunit_output.xml

# Kill the FTP Server pid
kill -9 ${FTP_SERVER_PID}