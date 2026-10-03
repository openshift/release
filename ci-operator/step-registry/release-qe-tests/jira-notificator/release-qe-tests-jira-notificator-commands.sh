#!/bin/bash
jira_username=$(cat "/var/run/vault/release-tests-token/jira_username")
export JIRA_USERNAME=$jira_username
jira_token=$(cat "/var/run/vault/release-tests-token/jira_token")
export JIRA_TOKEN=$jira_token
github_app_reader_id=$(cat "/var/run/vault/release-tests-token/github_app_reader_id")
export GITHUB_APP_READER_ID=$github_app_reader_id
github_app_reader_private_key="/var/run/vault/release-tests-token/github_app_reader_private_key"
export GITHUB_APP_READER_PRIVATE_KEY=$github_app_reader_private_key
oarctl jira-notificator
