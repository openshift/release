from content.utils import get_rc_volumes, get_rc_volume_mounts, get_rcapi_volume_mounts, get_rcapi_volumes, get_oc_volume_mounts


def _add_osd_rc_bootstrap(gendoc):
    context = gendoc.context

    gendoc.add_comments("""
    Bootstrap the environment for the amd64 tests image.  The caches require an amd64 "tests" image to execute on
    the cluster.  This imagestream is used as a commandline parameter to the release-controller...
         --tools-image-stream-tag=release-controller-bootstrap:tools
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
                        'name': 'image-registry.openshift-image-registry.svc:5000/ocp/4.16:tools'
                    },
                    'importPolicy': {
                        'scheduled': True
                    },
                    'name': 'tools',
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
                'name': context.rc_api_service_name,
            }
        }
    })


def _add_osd_rc_service(gendoc):
    annotations = {}
    annotationsAPI = {}
    context = gendoc.context

    if context.private:
        annotations['service.alpha.openshift.io/serving-cert-secret-name'] = context.secret_name_tls
        annotationsAPI['service.alpha.openshift.io/serving-cert-secret-name'] = context.secret_name_tls_api

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {
            'name': context.rc_service_name,
            'namespace': context.config.rc_deployment_namespace,
            'annotations': annotations,
            'labels': {
                'app': context.rc_service_name
            }
        },
        'spec': {
            'ports': [{
                'name': 'main',
                'port': 443 if context.private else 80,
                'targetPort': 8443 if context.private else 8080
            }],
            'selector': {
                'app': context.rc_service_name
            }
        }
    })
    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {
            'name': context.rc_api_service_name,
            'namespace': context.config.rc_deployment_namespace,
            'annotations': annotationsAPI,
            'labels': {
                'app': context.rc_api_service_name
            }
        },
        'spec': {
            'ports': [{
                'name': 'main',
                'port': 443 if context.private else 80,
                'targetPort': 8443 if context.private else 8080
            }],
            'selector': {
                'app': context.rc_api_service_name
            }
        }
    })


def _add_osd_rc_servicemonitor(gendoc):
    annotations = {}
    context = gendoc.context

    gendoc.append({
        'apiVersion': 'monitoring.coreos.com/v1',
        'kind': 'ServiceMonitor',
        'metadata': {
            'name': context.rc_service_name,
            'namespace': 'ci',
            'annotations': annotations,
        },
        'spec': {
            'endpoints': [{
                'interval': '30s',
                'port': 'main',
                'scheme': 'http',
            }],
            'selector': {
                'matchLabels': {
                    'app': context.rc_service_name,
                }
            }
        }
    })
    gendoc.append({
        'apiVersion': 'monitoring.coreos.com/v1',
        'kind': 'ServiceMonitor',
        'metadata': {
            'name': context.rc_api_service_name,
            'namespace': 'ci',
            'annotations': annotations,
        },
        'spec': {
            'endpoints': [{
                'interval': '30s',
                'port': 'main',
                'scheme': 'http',
            }],
            'namespaceSelector': {
                'matchNames': ['ci'],
            },
            'selector': {
                'matchLabels': {
                    'app': context.rc_api_service_name,
                }
            }
        }
    })


def _get_osd_rc_deployment_sidecars(context):
    sidecars = []

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
                     f'-client-id=system:serviceaccount:{context.config.rc_deployment_namespace}:release-controller-{context.is_namespace}',
                     '-openshift-ca=/etc/pki/tls/cert.pem',
                     '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                     '-openshift-sar={"verb": "get", "resource": "imagestreams", "namespace": "ocp-priv"}',
                     '-openshift-delegate-urls={"/": {"verb": "get", "group": "image.openshift.io", "resource": "imagestreams", "namespace": "ocp-priv"}}',
                     '-client-secret-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
                     '-cookie-secret-file=/etc/proxy/secrets/session_secret',
                     '-tls-cert=/etc/tls/private/tls.crt',
                     '-tls-key=/etc/tls/private/tls.key'],
            'image': 'quay.io/openshift/origin-oauth-proxy:4.16',
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

def get_oc_env_vars():
    return [
        {
            "name": "HOME",
            "value": "/tmp/home"
        },
        {
            "name": "XDG_RUNTIME_DIR",
            "value": "/tmp/home/run"
        }
    ]

def get_oc_prepare_container():
    return [
        {
            "name": "oc-prepare",
            "command": ["/bin/bash", "-c",
            """#!/bin/bash
set -euo pipefail
trap 'kill $(jobs -p); exit 0' TERM

SECONDS=0

# ensure we are logged in to our registry
mkdir -p ${XDG_RUNTIME_DIR}/containers
cp /tmp/pull-secret/auth.json ${XDG_RUNTIME_DIR}/containers/auth.json || true

# global git config stored to $HOME/.gitconfig which is shared with the main release-controller pods
git config --global credential.helper store
git config --global user.name test
git config --global user.email test@test.com
oc registry login --to ${XDG_RUNTIME_DIR}/containers/auth.json

FROM=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestreams/accepted | jq -r '.["4-stable"][0] // empty')
TO=$(curl -s https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestreams/accepted | jq -r '.["4-dev-preview"][0] // empty')

if [[ -n "$FROM" && -n "$TO" ]]
then
    echo "Pre-populating the git cache..."
    oc adm release info --changelog=/tmp/git quay.io/openshift-release-dev/ocp-release:$FROM-x86_64 quay.io/openshift-release-dev/ocp-release:$TO-x86_64
else
    echo "Unable to Pre-populate the git cache!"
fi

DURATION=$SECONDS
echo "Took: $(($DURATION / 60))m $(($DURATION % 60))s"
            """],
            "image": "release-controller:latest",
            "volumeMounts": get_oc_volume_mounts(),
            "env": get_oc_env_vars(),
        }
    ]


def _add_osd_rc_deployment(gendoc):
    context = gendoc.context
    extra_rc_args = [
        f'--release-namespace={context.is_namespace}',
    ]
    if not context.suffix:
        # The main x86_64 release controller also monitors origin
        extra_rc_args.append('--publish-namespace=origin')

    # Creating Cluster Groups for the AMD64 jobs...
    if context.arch == 'x86_64':
        extra_rc_args.append('--cluster-group=build01,build02,build03,build05')
        extra_rc_args.append('--cluster-group=vsphere')

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
                    "initContainers": [
                        {
                            "name": "git-sync-init",
                            "command": ["/git-sync"],
                            "args": [
                                "--repo=https://github.com/openshift/release.git",
                                "--ref=master",
                                "--root=/tmp/git-sync",
                                "--one-time=true",
                                "--depth=1",
                                "--link=release"
                            ],
                            "image": "quay-proxy.ci.openshift.org/openshift/ci:ci_git-sync_v4.3.0",
                            "volumeMounts": [
                                {
                                    "name": "release",
                                    "mountPath": "/tmp/git-sync"
                                }
                            ]
                        }] + get_oc_prepare_container(),
                    "containers": [
                        {
                            "name": "git-sync",
                            "command": ["/git-sync"],
                            "args": [
                                "--repo=https://github.com/openshift/release.git",
                                "--ref=master",
                                "--period=30s",
                                "--root=/tmp/git-sync",
                                "--max-failures=3",
                                "--link=release"
                            ],
                            "image": "quay-proxy.ci.openshift.org/openshift/ci:ci_git-sync_v4.3.0",
                            "volumeMounts": [
                                {
                                    "name": "release",
                                    "mountPath": "/tmp/git-sync"
                                }
                            ],
                            "resources": {
                                "requests": {
                                    "memory": "1Gi",
                                    "cpu": "0.5",
                                }
                            }
                        },
                        *_get_osd_rc_deployment_sidecars(context),
                        {
                            "resources": {
                                "requests": {
                                    "memory": "2Gi"
                                },
                            },
                            'command': ['/usr/bin/release-controller',
                                        *extra_rc_args,
                                        '--prow-config=/etc/config/config.yaml',
                                        '--supplemental-prow-config-dir=/etc/config',
                                        '--job-config=/var/repo/release/ci-operator/jobs',
                                        '--listen=' + ('127.0.0.1:8080' if context.private else ':8080'),
                                        f'--prow-namespace={context.config.rc_deployment_namespace}',
                                        f'--job-namespace={context.jobs_namespace}',
                                        '--tools-image-stream-tag=release-controller-bootstrap:tools',
                                        f'--release-architecture={context.get_supported_architecture_name()}',
                                        '-v=6',
                                        '--github-token-path=/etc/github/oauth',
                                        '--github-endpoint=http://ghproxy',
                                        '--github-graphql-endpoint=http://ghproxy/graphql',
                                        '--github-throttle=250',
                                        '--jira-endpoint=https://issues.redhat.com',
                                        '--jira-bearer-token-file=/etc/jira/api',
                                        '--verify-jira',
                                        '--plugin-config=/etc/plugins/plugins.yaml',
                                        '--supplemental-plugin-config-dir=/etc/plugins',
                                        '--authentication-message=Pulling these images requires <a href="https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/">authenticating to the app.ci cluster</a>.',
                                        f'--art-suffix={context.art_suffix}',
                                        "--manifest-list-mode"
                                        ],
                            'image': 'release-controller:latest',
                            'name': 'controller',
                            'volumeMounts': get_rc_volume_mounts(),
                            'env': get_oc_env_vars(),
                            'livenessProbe': {
                                'httpGet': {
                                    'path': '/healthz',
                                    'port': 8081
                                },
                                'initialDelaySeconds': 3,
                                'periodSeconds': 3,
                            },
                            'readinessProbe': {
                                'httpGet': {
                                    'path': '/healthz/ready',
                                    'port': 8081
                                },
                                'initialDelaySeconds': 10,
                                'periodSeconds': 3,
                                'timeoutSeconds': 600,
                            },
                        }],
                    'serviceAccountName': f'release-controller-{context.is_namespace}',
                    'volumes': get_rc_volumes(context)
                }
            }
        }
    })

    gendoc.append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'annotations': {
                'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"release-controller-api:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\\"controller\\")].image"}]'
            },
            'name': f'release-controller-api-{context.is_namespace}',
            'namespace': context.config.rc_deployment_namespace,
        },
        'spec': {
            'replicas': 3,
            'selector': {
                'matchLabels': {
                    'app': context.rc_api_service_name
                }
            },
            'template': {
                'metadata': {
                    'labels': {
                        'app': context.rc_api_service_name
                    }
                },
                'spec': {
                    'initContainers': get_oc_prepare_container(),
                    'containers': [
                        *_get_osd_rc_deployment_sidecars(context),
                        {
                            "resources": {
                                "requests": {
                                    "memory": "2Gi"
                                },
                            },
                            'command': ['/usr/bin/release-controller-api',
                                        # '--to=release',  # Removed according to release controller help
                                        f'--release-namespace={context.is_namespace}',
                                        f'--artifacts={context.fc_app_url}',
                                        f'--prow-namespace={context.config.rc_deployment_namespace}',
                                        f'--job-namespace={context.jobs_namespace}',
                                        '--tools-image-stream-tag=release-controller-bootstrap:tools',
                                        f'--release-architecture={context.get_supported_architecture_name()}',
                                        '-v=6',
                                        '--authentication-message=Pulling these images requires <a href="https://docs.ci.openshift.org/docs/how-tos/use-registries-in-build-farm/">authenticating to the app.ci cluster</a>.',
                                        f'--art-suffix={context.art_suffix}',
                                        '--enable-jira',
                                        '--jira-endpoint=https://issues.redhat.com',
                                        '--jira-bearer-token-file=/etc/jira/api',
                                        ],
                            'image': 'release-controller-api:latest',
                            'name': 'controller',
                            'volumeMounts': get_rcapi_volume_mounts(),
                            'env': get_oc_env_vars(),
                            'livenessProbe': {
                                'httpGet': {
                                    'path': '/healthz',
                                    'port': 8081
                                },
                                'initialDelaySeconds': 3,
                                'periodSeconds': 3,
                            },
                            'readinessProbe': {
                                'httpGet': {
                                    'path': '/healthz/ready',
                                    'port': 8081
                                },
                                'initialDelaySeconds': 10,
                                'periodSeconds': 3,
                                'timeoutSeconds': 600,
                            },
                        }],
                    'serviceAccountName': f'release-controller-{context.is_namespace}',
                    'volumes': get_rcapi_volumes(context, secret_name=context.secret_name_tls_api)
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
    _add_osd_rc_servicemonitor(gendoc)
    _add_osd_rc_deployment(gendoc)
