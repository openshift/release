def generate_signer_resources(gendoc):
    resources = gendoc
    context = gendoc.context

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-signer',
            'namespace': 'ocp'
        },
        'rules': [
            {
                'apiGroups': [''],
                'resourceNames': ['release-upgrade-graph'],
                'resources': ['secrets'],
                'verbs': ['get', 'list', 'watch']
            }
        ]
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-signer-binding',
            'namespace': 'ocp',
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-signer'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'release-controller',
            'namespace': context.config.rc_deployment_namespace
        }]
    })

    gendoc.add_comments("""
The signer watches all release tags and signs those that have the correct metadata and images are reachable (according
to an `oc adm release info --verify` invocation). Signatures a test that the specified release image was built within the
CI infrastructure or tagged in by a privileged user. Future versions of the verifier may add additional constraints.
The signer will sign both OKD, CI, and nightly releases, but nightly releases do not trust the CI signer.
        """)

    gendoc.append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'name': 'release-controller-signer',
            'namespace': 'ci',
            'annotations': {
                'keel.sh/policy': 'force',
                'keel.sh/matchTag': 'true',
                'keel.sh/trigger': 'poll',
                'keel.sh/pollSchedule': '@every 5m'
            }
        },
        'spec': {
            'replicas': 1,
            'selector': {
                'matchLabels': {
                    'app': 'release-controller-signer'
                }
            },
            'template': {
                'metadata': {
                    'labels': {
                        'app': 'release-controller-signer'
                    }
                },
                'spec': {
                    'serviceAccountName': 'release-controller',
                    'volumes': [{
                        'name': 'publisher',
                        'secret': {
                            'secretName': 'release-controller-signature-publisher'
                        }
                    }, {
                        'name': 'release-controller-kubeconfigs',
                        'secret': {
                            'secretName': 'release-controller-kubeconfigs',
                        }
                    }, {
                        'name': 'signer',
                        'secret': {
                            'secretName': 'release-controller-signature-signer'
                        }
                    }],
                    'containers': [{
                        'name': 'controller',
                        'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-controller_latest',
                        'imagePullPolicy': 'Always',
                        'volumeMounts': [{
                            'name': 'publisher',
                            'mountPath': '/etc/release-controller/publisher',
                            'readOnly': True
                        }, {
                            'name': 'release-controller-kubeconfigs',
                            'mountPath': '/etc/kubeconfigs',
                            'readOnly': True
                        }, {
                            'name': 'signer',
                            'mountPath': '/etc/release-controller/signer',
                            'readOnly': True
                        }],
                        'command': [
                            '/usr/bin/release-controller',
                            '--release-namespace=ocp',
                            '--release-namespace=origin',
                            '--job-namespace=ci-release',
                            '--tools-image-stream-tag=release-controller-bootstrap:tools',
                            '--audit=gs://openshift-ci-release/releases',
                            '--sign=/etc/release-controller/signer/openshift-ci.gpg',
                            '--audit-gcs-service-account=/etc/release-controller/publisher/service-account.json',
                            '-v=6'
                        ]
                    }]
                }
            }
        }
    })
