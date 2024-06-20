import configparser
import glob
import os


def add_rpm_mirror_service(gendoc, clone_dir, major_minor):
    hyphened_version = f'{major_minor.replace(".", "-")}'
    for repo_file in sorted(glob.glob(f'{clone_dir}/core-services/release-controller/_repos/ocp-{major_minor}-*.repo')):
        bn = os.path.splitext(os.path.basename(repo_file))[0]  # e.g. ocp-4.7-default

        # ngnix will create an endpoint in each pod, named after each repo
        # entry in the .repo file. We need to find one of these names
        # in order to formulate a good livenessProbe check which
        # will actually hit the upstream repos.
        repo_config = configparser.ConfigParser()
        repo_config.read(repo_file, encoding='utf-8')
        first_section_id = repo_config.sections()[0]

        # Unfortunately, there is a legacy mapping from .repo file to service name.
        # Perform that mapping now.
        file_prefix = f'ocp-{hyphened_version}-'
        repo_key = bn[len(file_prefix):]  # strip off prefix => "default" or "openstack-beta"

        if repo_key == 'openstack-beta':
            service_name = f'{repo_key}-{hyphened_version}'
        elif repo_key == 'default':
            service_name = f'base-{hyphened_version}'
        elif repo_key == 'openstack':
            service_name = f'base-openstack-{hyphened_version}'
        else:
            service_name = f'base-{hyphened_version}-{repo_key}'

        gendoc.append({
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': {
                'name': service_name,
                'namespace': 'ocp'
            },
            'spec': {
                'ports': [{
                    'port': 80,
                    'targetPort': 8080
                }],
                'selector': {
                    'app': service_name
                },
                'type': 'ClusterIP'
            }
        })
        gendoc.append({
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {
                'annotations': {
                    'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"content-mirror:latest","namespace":"ci"},"fieldPath":"spec.template.spec.containers[?(@.name==\\"mirror\\")].image"}]'
                },
                'labels': {
                    'app': service_name
                },
                'name': service_name,
                'namespace': 'ocp'
            },
            'spec': {
                'replicas': 2,
                'selector': {
                    'matchLabels': {
                        'app': service_name,
                    }
                },
                'template': {
                    'metadata': {
                        # Set safe-to-evict, otherwise this pods will inhibit autoscaling with
                        # their local storage.
                        'annotations': {
                            'cluster-autoscaler.kubernetes.io/safe-to-evict': 'true'
                        },
                        'labels': {
                            'app': service_name,
                        }
                    },
                    'spec': {
                        'containers': [{
                            'command': ['content-mirror',
                                        '--path=/tmp/config',
                                        '--max-size=5g',
                                        '--timeout=30m',
                                        '/tmp/repos',
                                        "/tmp/key",
                                        "/tmp/mirror-enterprise-basic-auth"],
                            'image': ' ',
                            'name': 'mirror',
                            'ports': [{
                                'containerPort': 8080,
                                'name': 'http'
                            }],
                            'volumeMounts': [
                                {
                                    'mountPath': '/tmp/repos',
                                    'name': 'repos',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/tmp/key',
                                    'name': 'key',
                                    'readOnly': True
                                },
                                {
                                    "mountPath": "/tmp/mirror-enterprise-basic-auth",
                                    "name": "mirror-enterprise-basic-auth",
                                    "readOnly": True
                                },
                                {
                                    'mountPath': '/tmp/cache',
                                    'name': 'cache'
                                }],
                            'resources': {
                                'requests': {
                                    'memory': "500Mi"
                                },
                            },
                            'workingDir': '/tmp/repos',
                            'livenessProbe': {
                                'httpGet': {
                                    # All repos have repomd.xml, so we should be able to read it.
                                    'path': f'/{first_section_id}/repodata/repomd.xml',
                                    'port': 8080,
                                },
                                'initialDelaySeconds': 120,
                                'periodSeconds': 120,
                            }
                        }],
                        'nodeSelector': {
                            'kubernetes.io/os': 'linux',
                            'kubernetes.io/arch': 'amd64'
                        },
                        'volumes': [
                            {
                                'configMap': {
                                    'items': [{
                                        'key': f'{bn}.repo',
                                        'path': f'{bn}.repo'
                                    }],
                                    'name': 'base-repos'
                                },
                                'name': 'repos'
                            },
                            {
                                'name': 'key',
                                'secret': {
                                    'secretName': 'mirror.openshift.com'
                                }
                            },
                            {
                                "name": "mirror-enterprise-basic-auth",
                                "secret": {
                                    "defaultMode": 420,
                                    "secretName": "mirror-enterprise-basic-auth"
                                }
                            },
                            {
                                'emptyDir': {},
                                'name': 'cache'
                            },
                            {
                                'emptyDir': {},
                                'name': 'run'
                            }]
                    }
                }
            }
        })
