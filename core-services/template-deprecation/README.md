# Template Deprecation Allowlist

This configuration tracks the template deprecation efforts (see [Migrating CI
Jobs from Templates to Multi-Stage Tests](https://docs.ci.openshift.org/docs/how-tos/migrating-template-jobs-to-multistage/)) for more information.

To update the allowlist, run `make template-allowlist` in the repository root.
If the command succeeds and updates the allowlist, the jobs can be added to the
allowlist. If it fails, it means that such change to the repository would be
refused by DPTP (via an automated check) because multi-stage workflows offer
all the necessary functionality, and the job should be used that instead. In this
case the tool provides links to the appropriate documentation about the migration.
