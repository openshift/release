{
  alertmanagerReceivers+:: [
    {
      name: 'slack-criticals',
      slack_configs: [
        {
          channel: '#ops-testplatform',
          api_url: '${SLACK_API_URL}',
          icon_url: 'https://avatars3.githubusercontent.com/u/3380462',
          text: '{{ template "custom_slack_text" . }}',
        },
      ],
      pagerduty_configs: [
        {
          service_key: '${PAGERDUTY_INTEGRATION_KEY}',
        },
      ],
    },
    {
      name: 'slack-warnings',
      slack_configs: [
        {
          channel: '#alerts-testplatform',
          api_url: '${SLACK_API_URL}',
          icon_url: 'https://avatars3.githubusercontent.com/u/3380462',
          text: '{{ template "custom_slack_text" . }}',
        },
      ],
    },
  ],
}
