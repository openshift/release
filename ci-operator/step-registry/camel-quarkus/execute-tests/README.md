# camel-quarkus-execute-tests-ref<!-- omit from toc -->

This script is very simple. 
It uses `oc_login.sh` file straight from the pulled image (to logging into oc), then runs the actual tests via `run.sh` script, and collect all Junit tests results into `ARTIFACT_DIR` under the `camel-quarkus-interop-aws/camel-quarkus-execute-tests` dedicated artifacts.

## Prerequisite(s)

There are no prerequisites for the tests executions.

### Infrastructure

- A provisioned AWS-ipi test cluster to target.
