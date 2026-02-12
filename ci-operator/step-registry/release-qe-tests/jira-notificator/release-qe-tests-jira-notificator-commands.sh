#!/bin/bash

jira_token=$(cat "/var/run/vault/release-tests-token/jira_token")
export JIRA_TOKEN=$jira_token
oarctl jira-notificator
