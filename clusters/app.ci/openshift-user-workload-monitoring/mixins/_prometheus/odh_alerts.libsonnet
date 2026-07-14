{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'odh-hive-pool-health',
        rules: [
          {
            alert: 'odh-pool-exhausted',
            expr: |||
              hive_clusterpool_clusterdeployments_assignable{clusterpool_name=~"odh-.*|opendatahub-.*"} == 0
            |||,
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'ODH Hive pool {{ $labels.clusterpool_name }} has no assignable clusters. E2e jobs will queue. Check the <https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/%s/odh-hive-pools-ci-health|ODH CI dashboard>.' % $._config.grafanaDashboardIDs['odh-hive-dashboard.json'],
            },
          },
          {
            alert: 'odh-clusters-stuck-installing',
            expr: |||
              hive_clusterpool_clusterdeployments_installing{clusterpool_name=~"odh-.*|opendatahub-.*"} > 5
            |||,
            'for': '30m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: 'ODH Hive pool {{ $labels.clusterpool_name }} has {{ $value }} clusters stuck installing. Check Hive logs on hosted-mgmt in namespace opendatahub-cluster-pool.',
            },
          },
        ],
      },
      {
        name: 'odh-e2e-job-health',
        rules: [
          {
            alert: 'odh-e2e-high-failure-rate',
            expr: |||
              sum(rate(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state="failure"}[2h]))
              /
              sum(rate(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state=~"success|failure"}[2h]))
              > 0.5
            |||,
            'for': '30m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: 'More than 50% of ODH e2e jobs are failing. Check recent failures at <https://prow.ci.openshift.org/?job=*opendatahub*e2e*|Prow>.',
            },
          },
        ],
      },
    ],
  },
}
