import os


def add_golang_builders(gendoc, clone_dir, major, minor):
    my_dir = os.path.dirname(__file__)
    my_relative_dir = os.path.relpath(my_dir, os.path.abspath(clone_dir))
    resources_dir = os.path.join(my_relative_dir, 'resources')
    major_minor = f'{major}.{minor}'

    for rhel_ver in ('7', '8'):
        image_base_name = f'rhel-{rhel_ver}-golang-openshift-{major_minor}'
        gendoc.append(
            {
                'apiVersion': 'v1',
                'kind': 'BuildConfig',
                'metadata': {
                    'name': f'{image_base_name}-builder',
                    'namespace': 'ci',
                },
                'spec': {
                    'failedBuildsHistoryLimit': 2,
                    'output': {
                        'to': {
                            'kind': 'ImageStreamTag',
                            'namespace': 'ocp',
                            'name': f'builder:{image_base_name}'
                        }
                    },
                    'source': {
                        'contextDir': f'{resources_dir}/Dockerfile.rhel-{rhel_ver}-golang',
                        'git': {
                            'ref': 'master',
                            'uri': 'https://github.com/openshift/release.git'
                        },
                        'type': 'Git'
                    },
                    'strategy': {
                        'dockerStrategy': {
                            'from': {
                                'kind': 'ImageStreamTag',
                                'name': f'builder:{image_base_name}.art',
                                'namespace': 'ocp'
                            },
                            'imageOptimizationPolicy': 'SkipLayers',
                            'buildArgs': [
                                {
                                    'name': 'MAJOR',
                                    'value': major,
                                },
                                {
                                    'name': 'MINOR',
                                    'value': minor,
                                },
                            ]
                        },
                    },
                    'successfulBuildsHistoryLimit': 2,
                    'triggers': [{
                        'imageChange': {},
                        'type': 'ImageChange'
                    }]
                }
            }, comment=f"""
ART builds many container first images with golang builder images. We want upstream CI
builds to use a builder image as close to the ART builder as possible. To that end, 
ART will mirror its builder images to api.ci. However, we cannot use these images directly
for CI. On top of the ART builders, we need to create yum repositories configuration 
files that will allow CI builds access to the same repositories available during an ART
build (see https://docs.google.com/document/d/1GqmPMzeZ0CmVZhdKF_Q_TdRqx_63TIRboO4uvqejPAY/edit#heading=h.kv09dibi95bt).

This build creates a RHEL-{rhel_ver} golang builder image for CI for OpenShift {major_minor}. 
        """)


def add_golang_release_builders(gendoc, clone_dir, major, minor):
    my_dir = os.path.dirname(__file__)
    my_relative_dir = os.path.relpath(my_dir, os.path.abspath(clone_dir))
    resources_dir = os.path.join(my_relative_dir, 'resources')
    major_minor = f'{major}.{minor}'

    for rhel_ver in ('7', '8'):
        image_base_name = f'rhel-{rhel_ver}-release-openshift-{major_minor}'
        golang_image_name = f'rhel-{rhel_ver}-golang-openshift-{major_minor}'
        gendoc.append(
            {
                'apiVersion': 'v1',
                'kind': 'BuildConfig',
                'metadata': {
                    'name': f'{image_base_name}-builder',
                    'namespace': 'ci',
                },
                'spec': {
                    'failedBuildsHistoryLimit': 2,
                    'output': {
                        'to': {
                            'kind': 'ImageStreamTag',
                            'namespace': 'openshift',
                            'name': f'release:{image_base_name}'
                        }
                    },
                    'source': {
                        'contextDir': f'{resources_dir}/Dockerfile.rhel-{rhel_ver}-release',
                        'git': {
                            'ref': 'master',
                            'uri': 'https://github.com/openshift/release.git'
                        },
                        'type': 'Git'
                    },
                    'strategy': {
                        'dockerStrategy': {
                            'from': {
                                'kind': 'ImageStreamTag',
                                'name': f'builder:{golang_image_name}',
                                'namespace': 'ocp'
                            },
                            'imageOptimizationPolicy': 'SkipLayers',
                            'buildArgs': [
                                {
                                    'name': 'MAJOR',
                                    'value': major,
                                },
                                {
                                    'name': 'MINOR',
                                    'value': minor,
                                },
                            ]
                        },
                    },
                    'successfulBuildsHistoryLimit': 2,
                    'triggers': [{
                        'imageChange': {},
                        'type': 'ImageChange'
                    }]
                }
            }, comment=f"""
ART builds many container first images with golang builder images. We want upstream CI
builds to use a builder image as close to the ART builder as possible. To that end, 
ART will mirror its builder images to api.ci. However, we cannot use these images directly
for CI. On top of the ART builders, we need to create yum repositories configuration 
files that will allow CI builds access to the same repositories available during an ART
build (see https://docs.google.com/document/d/1GqmPMzeZ0CmVZhdKF_Q_TdRqx_63TIRboO4uvqejPAY/edit#heading=h.kv09dibi95bt).

This builder image, now appropriate for CI, needs a few more tools to satisfy some 
CI testing & packaging tests. A "release" image is therefore built on top of the
builder image with these packages installed.

This build creates a RHEL-{rhel_ver} golang release image for CI for OpenShift {major_minor}. 
        """)


def add_base_image_builders(gendoc, clone_dir, major, minor):
    my_dir = os.path.dirname(__file__)
    my_relative_dir = os.path.relpath(my_dir, os.path.abspath(clone_dir))
    resources_dir = os.path.join(my_relative_dir, 'resources')
    major_minor = f'{major}.{minor}'

    for rhel_ver in ('7', '8'):
        image_base_name = f'rhel-{rhel_ver}-base-openshift-{major_minor}'
        gendoc.append(
            {
                'apiVersion': 'v1',
                'kind': 'BuildConfig',
                'metadata': {
                    'name': f'{image_base_name}-base',
                    'namespace': 'ci',
                },
                'spec': {
                    'failedBuildsHistoryLimit': 2,
                    'output': {
                        'to': {
                            'kind': 'ImageStreamTag',
                            'namespace': 'ocp',
                            'name': f'builder:{image_base_name}'
                        }
                    },
                    'source': {
                        'contextDir': f'{resources_dir}/Dockerfile.rhel-{rhel_ver}-base',
                        'git': {
                            'ref': 'master',
                            'uri': 'https://github.com/openshift/release.git'
                        },
                        'type': 'Git'
                    },
                    'strategy': {
                        'dockerStrategy': {
                            'from': {
                                'kind': 'ImageStreamTag',
                                'name': f'builder:{image_base_name}.art',
                                'namespace': 'ocp'
                            },
                            'imageOptimizationPolicy': 'SkipLayers',
                            'buildArgs': [
                                {
                                    'name': 'MAJOR',
                                    'value': major,
                                },
                                {
                                    'name': 'MINOR',
                                    'value': minor,
                                },
                            ]
                        },
                    },
                    'successfulBuildsHistoryLimit': 2,
                    'triggers': [{
                        'imageChange': {},
                        'type': 'ImageChange'
                    }]
                }
            }, comment=f"""
ART usually builds containers based off an custom updated ubi7 or 8 image (i.e. packages are 
more up-to-date than the ubi images on registry.access. We want upstream CI
builds to use base images as close to the ART base as possible. To that end, 
ART will mirror its base images to api.ci. However, we cannot use these images directly
for CI. On top of the ART images, we need to create yum repositories configuration 
files that will allow CI builds access to the same repositories available during an ART
build (see https://docs.google.com/document/d/1GqmPMzeZ0CmVZhdKF_Q_TdRqx_63TIRboO4uvqejPAY/edit#heading=h.kv09dibi95bt).

This build creates a RHEL-{rhel_ver} base image for CI for OpenShift {major_minor}. 
        """)
