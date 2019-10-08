{
  _config+:: {
    // Grafana dashboard IDs are necessary for stable links for dashboards
    grafanaDashboardIDs: {
      'build_cop.json': '6829209d59479d48073d09725ce807fa',
      'boskos.json': '628a36ebd9ef30d67e28576a5d5201fd',
      'canary.json': '247fa71a76bb8c5c12c0389b5d532941',
      'dptp.json': '8ce131e226b7fd2901c2fce45d4e21c1',
      'e2e_template_jobs.json': 'af88e642a76f37342fb52d475d52d965',
    },
    buildCopSuccessRateTargets: {
      'branch-.*-images': 100,
      'release-.*-4.1': 80,
      'release-.*-4.2': 80,
      'release-.*-upgrade.*': 80,
      'release-.*4.1.*4.2.*': 80,
    },
    alertManagerReceivers: {
      'build-cop': {
        team: 'build-cop',
        channel: '#build-cop-alerts',
        notify: 'build-cop',
      },
      'openshift-library': {
        team: 'developer-experience',
        channel: '#forum-devex',
        notify: 'devex',
      },
    },
  },
}
