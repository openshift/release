SBR (Storage-Based Remediation) — medik8s/storage-based-remediation.

POC presubmit e2e-system-tests-sbr-pr-aws-odf builds the operator from a PR tip
(rehearsal hack: storage-based-remediation#95), installs via operator-sdk run
bundle, deploys ODF+NFS on AWS (openshift-org-aws), clones openshift/rhwa-system-tests
main, and runs sbr-operator system-tests.

When adding/removing branches or OCP versions, update branch protection in
core-services/prow/02_config/medik8s/_prowconfig.yaml if applicable.
