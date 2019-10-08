{
  alertmanagerReceivers+:: [
    {
      name: 'slack-notifications',
      slack_configs: [
        {
          channel: '#ops-testplatform',
          api_url: '{{ api_url }}',
          icon_url: 'https://avatars3.githubusercontent.com/u/3380462',
          text: '{{ template "custom_slack_text" . }}',
        },
      ],
    },
  ],
}
