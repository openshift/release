

def _add_redirect_resources(gendoc):
    """
    Return resources necessary to redirect release controller requests to the
    OSD cluster instances where they live now.
    """
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

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Route',
        'metadata': {
            'name': f'release-controller-{context.is_namespace}',
            'namespace': 'ci'
        },
        'spec': {
            'host': f'openshift-release{context.suffix}.svc.ci.openshift.org',
            'tls': {
                'insecureEdgeTerminationPolicy': 'Redirect',
                'termination': 'Edge'
            },
            'to': {
                'kind': 'Service',
                'name': f'release-controller-{context.is_namespace}-redirect'
            }
        }
    })

    gendoc.append({
        'apiVersion': 'v1',
        'data': {
            'default.conf': 'server {\n  listen 8080;\n  return 302 https://%s$request_uri;\n}\n' % context.rc_app_url
        },
        'kind': 'ConfigMap',
        'metadata': {
            'name': f'release-controller-{context.is_namespace}-redirect-config',
            'namespace': context.config.rc_deployment_namespace
        }
    })

    gendoc.append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'labels': {
                'app': f'release-controller-{context.is_namespace}-redirect'
            },
            'name': f'release-controller-{context.is_namespace}-redirect',
            'namespace': context.config.rc_deployment_namespace
        },
        'spec': {
            'replicas': 2,
            'selector': {
                'matchLabels': {
                    'component': f'release-controller-{context.is_namespace}-redirect'
                }
            },
            'template': {
                'metadata': {
                    'labels': {
                        'app': 'prow',
                        'component': f'release-controller-{context.is_namespace}-redirect'
                    }
                },
                'spec': {
                    'affinity': {
                        'podAntiAffinity': {
                            'requiredDuringSchedulingIgnoredDuringExecution': [{
                                'labelSelector': {
                                    'matchExpressions': [
                                        {
                                            'key': 'component',
                                            'operator': 'In',
                                            'values': [
                                                f'release-controller-{context.is_namespace}-redirect']
                                        }]
                                },
                                'topologyKey': 'kubernetes.io/hostname'
                            }]
                        }
                    },
                    'containers': [{
                        'image': 'nginxinc/nginx-unprivileged:1.17',
                        'name': 'nginx',
                        'volumeMounts': [{
                            'mountPath': '/etc/nginx/conf.d',
                            'name': 'config'
                        }]
                    }],
                    'volumes': [{
                        'configMap': {
                            'name': f'release-controller-{context.is_namespace}-redirect-config'
                        },
                        'name': 'config'
                    }]
                }
            }
        }
    })

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {
            'labels': {
                'app': 'prow',
                'component': f'release-controller-{context.is_namespace}-redirect'
            },
            'name': f'release-controller-{context.is_namespace}-redirect',
            'namespace': 'ci'
        },
        'spec': {
            'ports': [{
                'name': 'main',
                'port': 8080,
                'protocol': 'TCP',
                'targetPort': 8080
            }],
            'selector': {
                'component': f'release-controller-{context.is_namespace}-redirect'
            },
            'sessionAffinity': 'None',
            'type': 'ClusterIP'
        }
    })


def _add_files_cache_redirect_resources(gendoc):
    """
    Return resources necessary to redirect the release controller's file-cache requests to the
    OSD cluster instances where they live now.
    """
    context = gendoc.context

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Route',
        'metadata': {
            'name': f'release-controller-files-cache-{context.is_namespace}',
            'namespace': context.jobs_namespace
        },
        'spec': {
            'host': f'{context.fc_api_url}',
            'tls': {
                'insecureEdgeTerminationPolicy': 'Redirect',
                'termination': 'Edge'
            },
            'to': {
                'kind': 'Service',
                'name': f'release-controller-files-cache-{context.is_namespace}-redirect'
            }
        }
    })

    gendoc.append({
        'apiVersion': 'v1',
        'data': {
            'default.conf': 'server {\n  listen 8080;\n  return 302 https://%s$request_uri;\n}\n' % context.fc_app_url
        },
        'kind': 'ConfigMap',
        'metadata': {
            'name': f'release-controller-files-cache-{context.is_namespace}-redirect-config',
            'namespace': context.jobs_namespace
        }
    })

    gendoc.append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'labels': {
                'app': f'release-controller-files-cache-{context.is_namespace}-redirect'
            },
            'name': f'release-controller-files-cache-{context.is_namespace}-redirect',
            'namespace': context.jobs_namespace
        },
        'spec': {
            'replicas': 2,
            'selector': {
                'matchLabels': {
                    'component': f'release-controller-files-cache-{context.is_namespace}-redirect'
                }
            },
            'template': {
                'metadata': {
                    'labels': {
                        'app': 'prow',
                        'component': f'release-controller-files-cache-{context.is_namespace}-redirect'
                    }
                },
                'spec': {
                    'affinity': {
                        'podAntiAffinity': {
                            'requiredDuringSchedulingIgnoredDuringExecution': [{
                                'labelSelector': {
                                    'matchExpressions': [
                                        {
                                            'key': 'component',
                                            'operator': 'In',
                                            'values': [
                                                f'release-controller-files-cache-{context.is_namespace}-redirect']
                                        }]
                                },
                                'topologyKey': 'kubernetes.io/hostname'
                            }]
                        }
                    },
                    'containers': [{
                        'image': 'nginxinc/nginx-unprivileged:1.17',
                        'name': 'nginx',
                        'volumeMounts': [{
                            'mountPath': '/etc/nginx/conf.d',
                            'name': 'config'
                        }]
                    }],
                    'volumes': [{
                        'configMap': {
                            'name': f'release-controller-files-cache-{context.is_namespace}-redirect-config'
                        },
                        'name': 'config'
                    }]
                }
            }
        }
    })

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {
            'labels': {
                'app': 'prow',
                'component': f'release-controller-files-cache-{context.is_namespace}-redirect'
            },
            'name': f'release-controller-files-cache-{context.is_namespace}-redirect',
            'namespace': context.jobs_namespace
        },
        'spec': {
            'ports': [{
                'name': 'main',
                'port': 80,
                'protocol': 'TCP',
                'targetPort': 8080
            }],
            'selector': {
                'component': f'release-controller-files-cache-{context.is_namespace}-redirect'
            },
            'sessionAffinity': 'None',
            'type': 'ClusterIP'
        }
    })


def add_redirect_resources(gendoc):
    _add_redirect_resources(gendoc)
    _add_files_cache_redirect_resources(gendoc)
