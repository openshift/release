{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ipi-deprovision',
        rules: [
          {
            alert: 'ipi-deprovision-failures',
            expr: |||
              rate(prowjob_state_transitions{job_name="periodic-ipi-deprovision",state="failure"}[30m]) > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'ipi-deprovision has failures. Check on <https://grafana-prow-monitoring.svc.ci.openshift.org/d/%s/dptp-dashboard?orgId=1&fullscreen&panelId=2|grafana> and <https://prow.svc.ci.openshift.org/?type=periodic&job=periodic-ipi-deprovision|deck>' % $._config.grafanaDashboardIDs['dptp.json'],
            },
          }
        ],
      },
    ],
  },
}
