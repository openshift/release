{
  _job_failures_config+:: {
    alerts: {
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
      'periodic-ci-kubevirt-hyperconverged-cluster-operator-release-4.5-hco-e2e-nightly-bundle-release-4-5-azure4': {
        receiver: 'openshift-virtualization',
      },
    },
  },
}
