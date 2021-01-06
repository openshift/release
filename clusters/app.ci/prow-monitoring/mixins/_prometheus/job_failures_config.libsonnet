{
  _job_failures_config+:: {
    alerts: {
      'periodic-openshift-library-import': {
        receiver: 'openshift-library',
      },
      'endurance-cluster-maintenance-aws-4.6': {
        receiver: 'endurance-cluster',
      },
      'periodic-ci-openshift-kni-cnf-features-deploy-master-cnf-e2e-gcp-periodic': {
        receiver: 'kni-cnf',
      },
      'periodic-ci-openshift-kni-cnf-features-deploy-release-4.5-cnf-e2e-gcp-periodic': {
        receiver: 'kni-cnf',
      },
      'periodic-ci-openshift-kni-cnf-features-deploy-release-4.4-cnf-e2e-gcp-periodic': {
        receiver: 'kni-cnf',
      },
      'release-openshift-ocp-installer-e2e-gcp-rt-4.4': {
        receiver: 'kni-cnf',
      },
      'release-openshift-ocp-installer-e2e-gcp-rt-4.5': {
        receiver: 'kni-cnf',
      },
      'release-openshift-ocp-installer-cluster-logging-operator-e2e-4.5': {
        receiver: 'openshift-logging',
      },
      'release-openshift-ocp-installer-elasticsearch-operator-e2e-4.5': {
        receiver: 'openshift-logging',
      },
      'periodic-ci-operator-framework-operator-lifecycle-managment-master-rhoperator-metric-e2e-aws-olm-master-daily': {
        receiver: 'OLM-rh-operators',
      },
      'periodic-ci-operator-framework-operator-lifecycle-managment-rhoperator-metric-e2e-aws-olm-release-4.5-daily': {
        receiver: 'OLM-rh-operators',
      },
      'periodic-ci-operator-framework-operator-lifecycle-managment-rhoperator-metric-e2e-aws-olm-release-4.4-daily': {
        receiver: 'OLM-rh-operators',
      },
      'periodic-ci-kubevirt-hyperconverged-cluster-operator-release-4.5-hco-e2e-nightly-bundle-release-4-5-azure4': {
        receiver: 'openshift-virtualization',
      },
    },
  },
}
