{
  _job_failures_config+:: {
    alerts: {
      'periodic-openshift-library-import': {
        receiver: 'openshift-library',
      },
      'endurance-cluster-maintenance-aws-4.3': {
        receiver: 'endurance-cluster',
      },
    },
  },
}
