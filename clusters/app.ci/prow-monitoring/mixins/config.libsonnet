{
  _config+:: {
    // Grafana dashboard IDs are necessary for stable links for dashboards
    grafanaDashboardIDs: {
      'build_cop.json': '6829209d59479d48073d09725ce807fa',
      'boskos.json': '628a36ebd9ef30d67e28576a5d5201fd',
      'boskos_http.json': 'd9f6dbcf30d14a12061638d2eb8e61ea8a5dd6b0',
      'boskos_acquire.json': '40efe201ce7f1e7a1fd247c13425534c757712ff',
      'canary.json': '247fa71a76bb8c5c12c0389b5d532941',
      'dptp.json': '8ce131e226b7fd2901c2fce45d4e21c1',
      'e2e_template_jobs.json': 'af88e642a76f37342fb52d475d52d965',
      'ghproxy.json': 'd72fe8d0400b2912e319b1e95d0ab1b3',
      'osde2e.json': '4238b58e99c5470481c2050f823e4fb9',
      'configresolver.json': '703f0ccf02cc4339a374b52eb10f653b',
    },
    buildCopSuccessRateTargets: {
      'branch-.*-images': 100,
      'release-.*-4.1': 80,
      'release-.*-4.2': 80,
      'release-.*-4.3': 80,
      'release-.*-upgrade.*': 80,
      'release-.*4.1.*4.2.*': 80,
      'release-.*4.2.*4.3.*': 80,
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
      'endurance-cluster': {
        team: 'build-cop',
        channel: '#build-cop-alerts',
        notify: 'bparees',
      },
      'kni-cnf': {
        team: 'cnf-cop',
        channel: '#cnf-alerts',
        notify: 'cnf-cop',
      },
      'openshift-logging': {
        team: 'logging',
        channel: '#forum-logging',
        notify: 'aoslogging',
      },
      'openshift-app-services': {
        team: 'openshift-app-services',
        channel: '#forum-app-services',
        notify: 'openshift-app-services',
      },
      'OLM-rh-operators': {
        team: 'OLM',
        channel: '#operator-test',
        notify: 'olmcop',
      },
      'openshift-virtualization': {
        team: 'openshift-virtualization',
        channel: '#kubevirt-ci-monitoring',
        notify: 'build-officer',
      },
    },
  },
}
