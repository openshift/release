# Prow Job State Pileup

Alerts: **TriggeredProwJobsPileup**, **SchedulingProwJobsPileup**.

## Triggered Peak Above Threshold

1. Open [Plank dashboard](https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/e1778910572e3552a935c2035ce80369/plank-dashboard).
2. In panel **"Number of Prow jobs by state with cluster"**, review overall `triggered` pressure across clusters.
3. Confirm the 5-minute `triggered` peak is above the configured alert threshold and determine if it is still rising.
4. Compare pressure against plank running-job limit (`max_concurrency`) from [core-services/prow/02_config/_config.yaml](https://github.com/openshift/release/blob/main/core-services/prow/02_config/_config.yaml).

## Scheduling Peak Above Threshold

1. Open [Plank dashboard](https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/e1778910572e3552a935c2035ce80369/plank-dashboard).
2. In panel **"Number of Prow jobs by state with cluster"**, review overall `scheduling` pressure across clusters.
3. Confirm the 5-minute `scheduling` peak is above the configured alert threshold and determine if it is still rising.
4. Compare current pressure to plank `max_concurrency` from [core-services/prow/02_config/_config.yaml](https://github.com/openshift/release/blob/main/core-services/prow/02_config/_config.yaml) to judge proximity to running-job limit.

