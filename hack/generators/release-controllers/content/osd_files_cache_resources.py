
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


def add_osd_files_cache_resources(gendoc):
    gendoc.add_comments("""
Resources required to deploy resources for the files-cache on
the app.ci clusters.
""")
    _add_files_cache_resources(gendoc)
