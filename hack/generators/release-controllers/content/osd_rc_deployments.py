

def _add_osd_rc_route(gendoc):
    context = gendoc.context
    gendoc.append({
        'apiVersion': 'route.openshift.io/v1',
        'kind': 'Route',
        'metadata': {
            'name': context.rc_route_name,
            'namespace': context.config.rc_deployment_namespace,
        },
        'spec': {
            'host': f'{context.rc_hostname}.{context.config.rc_deployment_domain}',
            'tls': {
                'insecureEdgeTerminationPolicy': 'Redirect',
                'termination': 'Reencrypt' if context.private else 'Edge'
            },
            'to': {
                'kind': 'Service',
                'name': context.rc_service_name,
            }
        }
    })


def _add_osd_rc_service(gendoc):
    annotations = {}
    context = gendoc.context

    if context.private:
        annotations['service.alpha.openshift.io/serving-cert-secret-name'] = context.secret_name_tls

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {
            'name': context.rc_service_name,
            'namespace': context.config.rc_deployment_namespace,
            'annotations': annotations,
        },
        'spec': {
            'ports': [{
                'port': 443 if context.private else 80,
                'targetPort': 8443 if context.private else 8080
            }],
            'selector': {
                'app': context.rc_service_name
            }
        }
    })


def _get_dynamic_rc_volume_mounts(context):
    prow_volume_mounts = []

    for major_minor in context.config.releases:
        prow_volume_mounts.append({
            'mountPath': f'/etc/job-config/{major_minor}',
            'name': f'job-config-{major_minor.replace(".", "")}',  # e.g. job-config-45
            'readOnly': True
        })

    return prow_volume_mounts


def _get_dynamic_deployment_volumes(context):
    prow_volumes = []

    if context.private:
        prow_volumes.append({
            'name': 'internal-tls',
            'secret': {
                'secretName': context.secret_name_tls,
            }
        })
        prow_volumes.append({
            'name': 'session-secret',
            'secret': {
                # clusters/app.ci/release-controller/admin_deploy-ocp-controller-session-secret.yaml
                'secretName': 'release-controller-session-secret',
            }
        })

    for major_minor in context.config.releases:
        prow_volumes.append({
            'configMap': {
                'defaultMode': 420,
                'name': f'job-config-{major_minor}'
            },
            'name': f'job-config-{major_minor.replace(".", "")}'
        })

    return prow_volumes


def _get_osd_rc_deployment_sidecars(context):
    sidecars = list()

    if context.private:
        sidecars.append({
            "resources": {
                "requests": {
                    "memory": "50Mi"
                },
            },
            'args': ['-provider=openshift',
                     '-https-address=:8443',
                     '-http-address=',
                     '-email-domain=*',
                     '-upstream=http://localhost:8080',
                     f'-client-id=system:serviceaccount:{context.config.rc_deployment_namespace}:release-controller',
                     '-openshift-ca=/etc/pki/tls/cert.pem',
                     '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                     '-openshift-sar={"verb": "get", "resource": "imagestreams", "namespace": "ocp-private"}',
                     '-openshift-delegate-urls={"/": {"verb": "get", "group": "image.openshift.io", "resource": "imagestreams", "namespace": "ocp-private"}}',
                     '-client-secret-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
                     '-cookie-secret-file=/etc/proxy/secrets/session_secret',
                     '-tls-cert=/etc/tls/private/tls.crt',
                     '-tls-key=/etc/tls/private/tls.key'],
            'image': 'openshift/oauth-proxy:latest',
            'imagePullPolicy': 'IfNotPresent',
            'name': 'oauth-proxy',
            'ports': [{
                'containerPort': 8443,
                'name': 'web'
            }],
            'volumeMounts': [
                {
                    'mountPath': '/etc/tls/private',
                    'name': 'internal-tls'
                },
                {
                    'mountPath': '/etc/proxy/secrets',
                    'name': 'session-secret'
                }]
        })
    return sidecars


def _add_osd_rc_deployment(gendoc):
    context = gendoc.context
    extra_rc_args = [
        f'--release-namespace={context.is_namespace}',
    ]
    if not context.suffix:
        # The main x86_64 release controller also monitors origin
        extra_rc_args.append('--publish-namespace=origin')

    gendoc.append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'annotations': {
                'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"release-controller:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\\"controller\\")].image"}]'
            },
            'name': f'release-controller-{context.is_namespace}',
            'namespace': context.config.rc_deployment_namespace,
        },
        'spec': {
            'replicas': 0,
            'selector': {
                'matchLabels': {
                    'app': context.rc_service_name
                }
            },
            'template': {
                'metadata': {
                    'labels': {
                        'app': context.rc_service_name
                    }
                },
                'spec': {
                    'containers': [
                        *_get_osd_rc_deployment_sidecars(context),
                        {
                            "resources": {
                                "requests": {
                                    "memory": "2Gi"
                                },
                            },
                            'command': ['/usr/bin/release-controller',
                                        # '--to=release',  # Removed according to release controller help
                                        *extra_rc_args,
                                        '--prow-config=/etc/config/config.yaml',
                                        '--job-config=/etc/job-config',
                                        f'--artifacts={context.hostname_artifacts}.{context.config.rc_release_domain}',
                                        '--listen=' + ('127.0.0.1:8080' if context.private else ':8080'),
                                        f'--prow-namespace={context.config.rc_deployment_namespace}',
                                        '--non-prow-job-kubeconfig=/etc/kubeconfig/kubeconfig',
                                        f'--job-namespace={context.jobs_namespace}',
                                        f'--tools-image-stream-tag=release-controller-bootstrap:tests',
                                        '-v=6',
                                        '--github-token-path=/etc/github/oauth',
                                        '--github-endpoint=http://ghproxy',
                                        '--github-graphql-endpoint=http://ghproxy/graphql',
                                        '--github-throttle=250',
                                        '--bugzilla-endpoint=https://bugzilla.redhat.com',
                                        '--bugzilla-api-key-path=/etc/bugzilla/api',
                                        '--plugin-config=/etc/plugins/plugins.yaml',
                                        '--verify-bugzilla'],
                            'image': 'release-controller:latest',
                            'name': 'controller',
                            'volumeMounts': [
                                {
                                    'mountPath': '/etc/config',
                                    'name': 'config',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/job-config/misc',
                                    'name': 'job-config-misc',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/job-config/master',
                                    'name': 'job-config-master',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/job-config/3.x',
                                    'name': 'job-config-3x',
                                    'readOnly': True
                                },
                                *_get_dynamic_rc_volume_mounts(context),
                                {
                                    'mountPath': '/etc/kubeconfig',
                                    'name': 'release-controller-kubeconfigs',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/github',
                                    'name': 'oauth',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/bugzilla',
                                    'name': 'bugzilla',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/plugins',
                                    'name': 'plugins',
                                    'readOnly': True
                                }]
                        }],
                    'serviceAccountName': 'release-controller',
                    'volumes': [
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'config'
                            },
                            'name': 'config'
                        },
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'job-config-misc'
                            },
                            'name': 'job-config-misc'
                        },
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'job-config-master'
                            },
                            'name': 'job-config-master'
                        },
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'job-config-3.x'
                            },
                            'name': 'job-config-3x'
                        },
                        *_get_dynamic_deployment_volumes(context),
                        {
                            'name': 'release-controller-kubeconfigs',
                            'secret': {
                                'items': [{
                                    'key': f'sa.release-controller-{context.is_namespace}.api.ci.config',
                                    'path': 'kubeconfig'
                                }],
                                'secretName': 'release-controller-kubeconfigs'
                            }
                        },
                        {
                            'name': 'oauth',
                            'secret': {
                                'secretName': 'github-credentials-openshift-ci-robot'
                            }
                        },
                        {
                            'name': 'bugzilla',
                            'secret': {
                                'secretName': 'bugzilla-credentials-openshift-bugzilla-robot'
                            }
                        },
                        {
                            'configMap': {
                                'name': 'plugins'
                            },
                            'name': 'plugins'
                        }]
                }
            }
        }
    })


def add_osd_rc_deployments(gendoc):
    gendoc.add_comments("""
Resources required to deploy release controller instances on
the app.ci clusters.
""")
    _add_osd_rc_route(gendoc)
    _add_osd_rc_service(gendoc)
    _add_osd_rc_deployment(gendoc)
