ci-chat-bot
===========

Source code for the controller is at https://github.com/openshift/ci-chat-bot

The chat bot uses the CI system to launch clusters via ProwJobs, reusing the same infrastructure
as our CI environments to make reproducing current flakes as painless as possible. It leverages
the jobs defined in `ci-operator/jobs/openshift/release/openshift-release-periodics.yaml` to
launch those clusters, and relies on Prow to tear down the cluster afterwards.

The bot token is managed as a secret in bitwarden and it uses similar permissions to the release
controller to launch new ProwJobs and extract content from their clusters.