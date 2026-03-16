SBR (Storage-Based Remediation) operator - medik8s/sbr-operator.
E2E runs on AWS (medik8s-aws profile). Operator installs via OLM into sbd-operator-system.

When adding/removing branches or OCP versions, update branch protection in
core-services/prow/02_config/medik8s/_prowconfig.yaml if applicable.
