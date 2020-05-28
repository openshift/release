{
  "kind": "Template",
  "apiVersion": "template.openshift.io/v1",
  "metadata": {
    "name": "alertmanager-prow-secret"
  },
  "parameters": [
      {
        "name": "SLACK_API_URL",
        "description": "The SLACK API URL",
        "required": true
      },
      {
        "description": "prow monitoring namespace",
        "name": "PROW_MONITORING_NAMESPACE",
        "value": "prow-monitoring"
      },
    ],
  "objects": [
    {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: 'alertmanager-prow',
        namespace: '${PROW_MONITORING_NAMESPACE}',
      },
      stringData: {
        "alertmanager.yaml": |||
              %s
            ||| % (importstr "../prometheus_out/_alertmanager.yaml"),
        "msg.tmpl": |||
              {{ define "custom_slack_text" }}{{ .CommonAnnotations.message }}{{ end }}
            |||,
      }
    }
  ]
}
