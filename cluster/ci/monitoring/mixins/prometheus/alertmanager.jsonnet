local receivers = (import 'alertmanager.libsonnet').alertmanagerReceivers;
local routes = (import 'alertmanager.libsonnet').alertmanagerRoutes;

{
  global: {
    resolve_timeout: '5m',
  },
  route: {
    group_by: [
      'alertname',
      'job',
    ],
    group_wait: '30s',
    group_interval: '5m',
    repeat_interval: '2h',
    receiver: 'slack-warnings',
    routes: routes,
  },
  receivers: receivers,
  templates: [
    '*.tmpl',
  ],
}
