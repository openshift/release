{
  "kind": "Template",
  "apiVersion": "template.openshift.io/v1",
  "metadata": {
    "name": "alertmanager-user-workload-secret"
  },
  "parameters": [
      {
        "name": "SLACK_API_URL",
        "description": "The SLACK API URL",
        "required": true
      },
      {
        "name": "PAGERDUTY_INTEGRATION_KEY",
        "description": "The PagerDuty integration key",
        "required": true
      },
      {
        "description": "monitoring namespace",
        "name": "MONITORING_NAMESPACE",
        "value": "openshift-user-workload-monitoring"
      },
    ],
  "objects": [
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'alertmanager-user-workload',
        namespace: '${MONITORING_NAMESPACE}',
      },
      stringData: {
        "alertmanager.yaml": |||
              %s
            ||| % (importstr "../tmp/_alertmanager.yaml"),
      }
    }
  ]
}
