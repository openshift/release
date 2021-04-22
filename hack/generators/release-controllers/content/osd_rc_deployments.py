
from content.utils import get_rc_volumes, get_rc_volume_mounts


def _add_osd_rc_bootstrap(gendoc):
    context = gendoc.context

    gendoc.add_comments("""
    Bootstrap the environment for the amd64 tests image.  The caches require an amd64 "tests" image to execute on
    the cluster.  This imagestream is used as a commandline parameter to the release-controller...
         --tools-image-stream-tag=release-controller-bootstrap:tests
        """)
    gendoc.append({
        'apiVersion': 'image.openshift.io/v1',
        'kind': 'ImageStream',
        'metadata': {
            'name': 'release-controller-bootstrap',
            'namespace': context.is_namespace
        },
        'spec': {
            'lookupPolicy': {
                'local': False
            },
            'tags': [
                {
                    'from': {
                        'kind': 'DockerImage',
                        'name': 'image-registry.openshift-image-registry.svc:5000/ocp/4.6:tests'
                    },
                    'importPolicy': {
                        'scheduled': True
                    },
                    'name': 'tests',
                    'referencePolicy': {
                        'type': 'Source'
                    }
                }]
        }
    })


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
            'host': f'{context.rc_app_url}',
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
            'replicas': 1,
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
                                        '--supplemental-prow-config-dir=/etc/config',
                                        '--job-config=/etc/job-config',
                                        f'--artifacts={context.fc_app_url}',
                                        '--listen=' + ('127.0.0.1:8080' if context.private else ':8080'),
                                        f'--prow-namespace={context.config.rc_deployment_namespace}',
                                        '--non-prow-job-kubeconfig=/etc/kubeconfig/kubeconfig',
                                        f'--job-namespace={context.jobs_namespace}',
                                        '--tools-image-stream-tag=release-controller-bootstrap:tests',
                                        f'--release-architecture={context.get_supported_architecture_name()}',
                                        '-v=6',
                                        '--github-token-path=/etc/github/oauth',
                                        '--github-endpoint=http://ghproxy',
                                        '--github-graphql-endpoint=http://ghproxy/graphql',
                                        '--github-throttle=250',
                                        '--bugzilla-endpoint=https://bugzilla.redhat.com',
                                        '--bugzilla-api-key-path=/etc/bugzilla/api',
                                        '--plugin-config=/etc/plugins/plugins.yaml',
                                        '--verify-bugzilla',
                                        '--authentication-message="Pulling these images requires <a href=\"https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/\">authenticating to the app.ci cluster</a>."'],
                            'image': 'release-controller:latest',
                            'name': 'controller',
                            'volumeMounts': get_rc_volume_mounts(context)
                        }],
                    'serviceAccountName': f'release-controller-{context.is_namespace}',
                    'volumes': get_rc_volumes(context, context.is_namespace)
                }
            }
        }
    })


def add_osd_rc_deployments(gendoc):
    gendoc.add_comments("""
Resources required to deploy release controller instances on
the app.ci clusters.
""")
    _add_osd_rc_bootstrap(gendoc)
    _add_osd_rc_route(gendoc)
    _add_osd_rc_service(gendoc)
    _add_osd_rc_deployment(gendoc)
