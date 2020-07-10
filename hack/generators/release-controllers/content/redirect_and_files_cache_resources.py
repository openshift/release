

def _add_files_cache_resources(gendoc):
    context = gendoc.context

    if not context.private:
        gendoc.add_comments("""
The release controller creates a files cache stateful set in each ci-release namespace
used by a release controller. Create a service and a route to this public instance.        
        """)
        gendoc.append({
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {
                'name': 'files-cache',
                'namespace': context.jobs_namespace
            },
            'spec': {
                'ports': [{
                    'port': 80,
                    'targetPort': 8080
                }],
                'selector': {
                    'app': 'files-cache'
                }
            }
        })

        gendoc.append({
            'apiVersion': 'v1',
            'kind': 'Route',
            'metadata': {
                'name': 'files-cache',
                'namespace': context.jobs_namespace
            },
            'spec': {
                'host': f'openshift-release-artifacts{context.suffix}.svc.ci.openshift.org',
                'tls': {
                    'insecureEdgeTerminationPolicy': 'Redirect',
                    'termination': 'Edge'
                },
                'to': {
                    'kind': 'Service',
                    'name': 'files-cache'
                }
            }
        })
    else:

        gendoc.add_comments("""
        The release controller creates a files cache stateful set in each ci-release namespace
        used by a release controller. This is a private instance and we need to place and oauth
        proxy in front of the normal service.        
                """)

        # In private mode, we setup an oauth proxy in front of the files cache.
        gendoc.append({
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {
                'name': 'files-cache',
                'namespace': context.jobs_namespace,
            },
            'spec': {
                'ports': [{
                    'port': 80,
                    'targetPort': 8080
                }],
                'selector': {
                    'app': 'files-cache'
                }
            }
        })

        gendoc.append({
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {
                'annotations': {
                    'service.alpha.openshift.io/serving-cert-secret-name': 'files-cache-oauth-proxy-tls'
                },
                'name': 'files-cache-oauth-proxy',
                'namespace': context.jobs_namespace,
            },
            'spec': {
                'ports': [{
                    'port': 443,
                    'targetPort': 8443
                }],
                'selector': {
                    'app': 'files-cache-oauth-proxy'
                }
            }
        })

        gendoc.append({
            'apiVersion': 'v1',
            'kind': 'Route',
            'metadata': {
                'name': 'files-cache-oauth-proxy',
                'namespace': context.jobs_namespace,
            },
            'spec': {
                'host': f'openshift-release-artifacts{context.suffix}.svc.ci.openshift.org',
                'tls': {
                    'insecureEdgeTerminationPolicy': 'Redirect',
                    'termination': 'Reencrypt'
                },
                'to': {
                    'kind': 'Service',
                    'name': 'files-cache-oauth-proxy'
                }
            }
        })

        gendoc.add_comments("""
Oauth proxy instance that protects to the private files cache for this private release controller
instance.
        """)
        gendoc.append({
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {
                'name': 'files-cache-oauth-proxy',
                'namespace': context.jobs_namespace,
            },
            'spec': {
                'selector': {
                    'matchLabels': {
                        'app': 'files-cache-oauth-proxy'
                    }
                },
                'template': {
                    'metadata': {
                        'labels': {
                            'app': 'files-cache-oauth-proxy'
                        }
                    },
                    'spec': {
                        'containers': [{
                            'args': ['-provider=openshift',
                                     '-https-address=:8443',
                                     '-http-address=',
                                     '-email-domain=*',
                                     f'-upstream=http://files-cache.{context.jobs_namespace}:80',
                                     f'-client-id=system:serviceaccount:{context.jobs_namespace}:files-cache-oauth',
                                     '-openshift-ca=/etc/pki/tls/cert.pem',
                                     '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                                     '-openshift-sar={"verb": "get", "resource": "imagestreams", "namespace": "%s"}' % context.is_namespace,
                                     '-openshift-delegate-urls={"/": {"verb": "get", "resource": "imagestreams", "namespace": "%s"}}' % context.is_namespace,
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
                        }],
                        'serviceAccountName': 'files-cache-oauth',
                        'volumes': [
                            {
                                'name': 'session-secret',
                                'secret': {
                                    'secretName': 'files-cache-session-secret'
                                }
                            },
                            {
                                'name': 'internal-tls',
                                'secret': {
                                    'secretName': 'files-cache-oauth-proxy-tls'
                                }
                            }]
                    }
                }
            }
        })


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
                        'name': 'registry.svc.ci.openshift.org/ocp/4.5:tests'
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
            'default.conf': 'server {\n  listen 8080;\n  return 302 https://%s.%s$request_uri;\n}\n' % (
                context.rc_hostname, context.config.rc_deployment_domain)
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


def add_redirect_and_files_cache_resources(gendoc):
    _add_redirect_resources(gendoc)
    _add_files_cache_resources(gendoc)
