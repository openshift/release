#!/bin/bash
jira_username=$(cat "/var/run/vault/release-tests-token/jira_username")
export JIRA_USERNAME=$jira_username
jira_token=$(cat "/var/run/vault/release-tests-token/jira_token")
export JIRA_TOKEN=$jira_token
oarctl jira-notificator
