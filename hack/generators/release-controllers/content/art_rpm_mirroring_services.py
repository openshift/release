import glob
import os


def add_rpm_mirror_service(gendoc, clone_dir, major_minor):
    hyphened_version = f'{major_minor.replace(".", "-")}'
    for repo_file in sorted(glob.glob(f'{clone_dir}/core-services/release-controller/_repos/ocp-{major_minor}-*.repo')):
        bn = os.path.splitext(os.path.basename(repo_file))[0]  # e.g. ocp-4.7-default

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
                        'labels': {
                            'app': service_name
                        }
                    },
                    'spec': {
                        'containers': [{
                            'command': ['content-mirror',
                                        '--path=/tmp/config',
                                        '--max-size=5g',
                                        '--timeout=30m',
                                        '/tmp/repos'],
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
                                    'mountPath': '/tmp/cache',
                                    'name': 'cache'
                                }],
                            'resources': {
                                'requests': {
                                    'memory': "500Mi"
                                },
                            },
                            'workingDir': '/tmp/repos'
                        }],
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
