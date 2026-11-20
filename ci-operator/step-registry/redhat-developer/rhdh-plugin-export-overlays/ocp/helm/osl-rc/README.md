# OSL release-candidate smoke test

Trigger `periodic-ci-redhat-developer-rhdh-plugin-export-overlays-<branch>-e2e-ocp-helm-osl-rc`
for `main` or `release-2.1` using the [Gangway REST API](https://docs.ci.openshift.org/docs/how-tos/triggering-prowjobs-via-rest/).
These periodics do not run on a schedule. The Helm nightlies are unchanged.

Select the Logic IIB for the OCP minor in the job's `cluster_claim`. Resolve its
tag to a digest and read the exact Logic CSV and channel from the catalog.
Set these keys under `pod_spec_options.envs`:

- `MULTISTAGE_PARAM_OVERRIDE_OSL_IIB`: `registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:<digest>`
- `MULTISTAGE_PARAM_OVERRIDE_OSL_OCP_VERSION`: the OCP minor the candidate targets.
- `MULTISTAGE_PARAM_OVERRIDE_OSL_STARTING_CSV`: exact `logic-operator.v...` from the catalog.
- `MULTISTAGE_PARAM_OVERRIDE_OSL_CHANNEL`: optional; defaults to `stable`.
- `MULTISTAGE_PARAM_OVERRIDE_OSL_OPERATOR_DIGEST`: optional; verifies the digest of the operator image in the installed CSV.

The setup uses mounted registry credentials, never Gangway inputs. The shared
overlays runner tests only Orchestrator and saves its reports as job artifacts.
RC runs use the official overlays repository and the job's configured branch.
Rehearsals without any candidate inputs exercise GA and do not validate the RC setup.
RC runs reject overlays revisions without `ORCHESTRATOR_STRICT_DATA_INDEX`
support. Land that change on both overlays branches before enabling the jobs.
RC runs retain test namespaces for Prow's gather step.
