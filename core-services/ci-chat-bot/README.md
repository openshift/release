This folder contains extra configuration for the ci-chat-bot (a.k.a. cluster-bot) service.

The `workflows-config.yaml` file defines what workflows from the step-registry can be run
via the `workflow-launch` slack command. Each workflow item has 3 fields that can be configured:
- `platform`: This field is required and must match a ci-chat-bot platform (eg. `aws`, `gcp`,`azure`, etc.)
- `architecture`: The architecture to run the cluster on. Currently, ci-chat-bot only supports `amd64`. If/when
  the chat-bot supports more platforms, that will be configurable via this field.
- `base_images`: This field is for any `base_images` that need to be included in the ci-operator config for the job.
  The format is identical to the ci-operator config format for `base_images`.

The struct definition for the above config file can be found in https://github.com/openshift/ci-chat-bot/blob/master/cmd/ci-chat-bot/main.go.
For any questions, please contact #forum-ocp-crt on the Internal Red Hat Slack.
