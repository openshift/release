export JIRA_TOKEN=$(cat "/var/run/vault/release-tests-token/jira_token")
oarctl jira-notificator --dry-run
