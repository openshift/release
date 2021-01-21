
def generate_signer_resources(gendoc):

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
                'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"release-controller:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\\\"controller\\\")].image"}]'
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
                            'items': [{
                                'key': 'sa.release-controller-ocp.app.ci.config',
                                'path': 'kubeconfig'
                            }]
                        }
                    }, {
                        'name': 'signer',
                        'secret': {
                            'secretName': 'release-controller-signature-signer'
                        }
                    }],
                    'containers': [{
                        'name': 'controller',
                        'image': 'release-controller:latest',
                        'volumeMounts': [{
                            'name': 'publisher',
                            'mountPath': '/etc/release-controller/publisher',
                            'readOnly': True
                        }, {
                            'name': 'release-controller-kubeconfigs',
                            'mountPath': '/etc/kubeconfig',
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
                            '--non-prow-job-kubeconfig=/etc/kubeconfig/kubeconfig',
                            '--tools-image-stream-tag=4.6:tests',
                            '--audit=gs://openshift-ci-release/releases',
                            '--sign=/etc/release-controller/signer/openshift-ci.gpg',
                            '--audit-gcs-service-account=/etc/release-controller/publisher/service-account.json',
                            '-v=4'
                        ]
                    }]
                }
            }
        }
    })
