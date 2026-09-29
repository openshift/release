# Agent model authorization policy

The `agent-model-policy` presubmit ensures that only authorized models are used
by definitions in `ci-operator/step-registry` and `ci-operator/jobs`. Model-use
exceptions are recorded by exact repository-relative path in
`authorized-paths.txt`.

Authorization is a guardrail, not a recommendation to select the most capable
model. Even when a capable model is approved by default, choose deliberately
for the task and consider capability, quality, latency, and price/performance.
Avoid using a more expensive model when a less expensive model is a better fit.

Exceptions to the models approved by default require approval from SHIP staff
engineers. This directory does not inherit parent OWNERS, so only the SHIP staff
engineers listed in `OWNERS` can approve changes to model-use authorizations.

Run the same check locally from the repository root:

```console
$ ci-operator/model-policy/validate.sh
```
