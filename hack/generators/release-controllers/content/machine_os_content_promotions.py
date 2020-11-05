import yaml

# Turn off too many statements
# pylint: disable=R0915

from . import Context, Config


def _make_promotion_job(major, minor, priv):
    major_minor = f'{major}.{minor}'

    # At present, ocp:is/4.x and ocp-private:is/4.x-priv are the key imagestreams
    # from which CI feeds. There are no arch specific streams being populated, so this
    # method does not attempt to promote arch specific machine-os-content. Only
    # x86_64 is handled.

    rhcos_source_ns = 'rhcos'
    # If this method is made multi-arch aware, the istag would be machine-os-content:4.x-<arch>
    rhcos_source_istag = f'machine-os-content:{major_minor}'
    qualified_source = f'{rhcos_source_ns} istag/{rhcos_source_istag}'  # for human readable messages

    # Where are we going to promote rhcos if the CI tests pass?
    dest_ns = 'ocp-private' if priv else 'ocp'
    dest_is = f'{major_minor}-priv' if priv else major_minor
    dest_tag = 'machine-os-content'
    dest_istag = f'{dest_is}:{dest_tag}'
    qualified_dest = f'{dest_ns} istag/{dest_istag}'  # for human readable messages

    promotion_script = f"""
#!/bin/bash
set -euo pipefail

# NOTE: This is generated bash. This is why you will see static variables compared against literals.

# prow doesn't allow init containers or a second container
export PATH=$PATH:/tmp/bin
mkdir /tmp/bin
curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.5/linux/oc.tar.gz | tar xvzf - -C /tmp/bin/ oc
chmod ug+x /tmp/bin/oc

# if the source and destination are identical, do nothing
from=$( oc get istag --ignore-not-found -n "{rhcos_source_ns}" "{rhcos_source_istag}" -o template='{{{{ .image.metadata.name }}}}' )

if [[ -z "$from" ]]; then
    echo "There is currently no {qualified_source} image available"
    exit 1
fi

to=$( oc get istag --ignore-not-found -n {dest_ns} "{dest_istag}" -o template='{{{{ .image.metadata.name }}}}' )
if [[ "$from" == "$to" ]]; then
    echo "info: {qualified_source} matches {qualified_dest} (currently $to); no action necessary"
    exit 0
fi
echo "Will promote {qualified_source} ($from), to {qualified_dest} (current value: $to)"

# error out if the image isn't on quay
to_quay="quay.io/openshift-release-dev/ocp-v4.0-art-dev@$from"
if ! oc image info -a "/usr/local/pull-secret/.dockerconfigjson" "$to_quay"; then
    echo "error: The source image has not been pushed to quay; missing $to_quay"
    exit 1
fi

# verify the tests pass
ci-operator $@
"""

    config_spec = {
        "tests": [
            {
                "as": "e2e-aws",
                "commands": "TEST_SUITE=openshift/conformance/parallel run-tests",
                "openshift_installer": {
                    "cluster_profile": "aws"
                }
            }
        ],
        "raw_steps": [
            {
                "output_image_tag_step": {
                    "to": {
                        "tag": dest_tag,
                        "name": "stable"
                    },
                    "from": dest_tag
                }
            }
        ],
        "build_root": {
            "image_stream_tag": {
                "tag": "golang-1.12",
                "namespace": "openshift",
                "name": "release"
            }
        },
        "promotion": {
            "namespace": dest_ns,
            "name": dest_is
        },
        "base_images": {
            dest_tag: {
                "tag": major_minor,
                "namespace": rhcos_source_ns,
                "name": 'machine-os-content'
            }
        },
        "resources": {
            "*": {
                "requests": {
                    "cpu": "100m",
                    "memory": "200Mi"
                },
                "limits": {
                    "memory": "4Gi"
                }
            }
        },
        "tag_specification": {
            "namespace": dest_ns,
            "name": dest_is
        }
    }

    prow_job = {
        'agent': 'kubernetes',
        'cluster': 'api.ci',
        'decorate': True,
        'hidden': priv,
        'interval': '15m',
        'labels': {
            'ci.openshift.io/release-type': 'informing',
            'job-release': f'{major_minor}'
        },
        'name': f'promote-release-openshift-machine-os-content-e2e-aws-{dest_is}',
        'spec': {
            'containers': [
                {
                    'args': [
                        '--artifact-dir=$(ARTIFACTS)',
                        '--kubeconfig=/etc/apici/kubeconfig',
                        '--lease-server-password-file=/etc/boskos/password',
                        '--lease-server-username=ci',
                        '--lease-server=https://boskos-ci.svc.ci.openshift.org',
                        '--secret-dir=/usr/local/pull-secret',
                        '--secret-dir=/usr/local/e2e-aws-cluster-profile',
                        '--template=/usr/local/e2e-aws',
                        '--input-hash=$(BUILD_ID) --input-hash=$(JOB_NAME)',
                        '--promote'
                    ],
                    'command': [
                        '/bin/bash',
                        '-c',
                        promotion_script
                    ],
                    'env': [
                        {
                            'name': 'CLUSTER_TYPE',
                            'value': 'aws'
                        },
                        {
                            'name': 'CONFIG_SPEC',
                            'value': yaml.safe_dump(config_spec, default_flow_style=False)
                        },
                        {
                            'name': 'JOB_NAME_SAFE',
                            'value': 'e2e-aws'
                        },
                        {
                            'name': 'TEST_COMMAND',
                            'value': 'TEST_SUITE=openshift/conformance/parallel run-tests'
                        }
                    ],
                    'image': 'ci-operator:latest',
                    'imagePullPolicy': 'Always',
                    'name': '',
                    'resources': {
                        'requests': {
                            'cpu': '10m'
                        }
                    },
                    'volumeMounts': [
                        {
                            'mountPath': '/etc/apici',
                            'name': 'apici-ci-operator-credentials',
                            'readOnly': True
                        },
                        {
                            'mountPath': '/etc/boskos',
                            'name': 'boskos',
                            'readOnly': True
                        },
                        {
                            'mountPath': '/usr/local/e2e-aws-cluster-profile',
                            'name': 'cluster-profile'
                        },
                        {
                            'mountPath': '/usr/local/e2e-aws',
                            'name': 'job-definition',
                            'subPath': 'cluster-launch-installer-e2e.yaml'
                        },
                        {
                            'mountPath': '/usr/local/pull-secret',
                            'name': 'release-pull-secret'
                        }
                    ]
                }
            ],
            'serviceAccountName': 'ci-operator',
            'volumes': [
                {
                    'name': 'apici-ci-operator-credentials',
                    'secret': {
                        'items': [
                            {
                                'key': 'sa.ci-operator.apici.config',
                                'path': 'kubeconfig'
                            }
                        ],
                        'secretName': 'apici-ci-operator-credentials'
                    }
                },
                {
                    'name': 'boskos',
                    'secret': {
                        'items': [
                            {
                                'key': 'password',
                                'path': 'password'
                            }
                        ],
                        'secretName': 'boskos-credentials'
                    }
                },
                {
                    'name': 'cluster-profile',
                    'projected': {
                        'sources': [
                            {
                                'secret': {
                                    'name': 'cluster-secrets-aws'
                                }
                            }
                        ]
                    }
                },
                {
                    'configMap': {
                        'name': 'prow-job-cluster-launch-installer-e2e'
                    },
                    'name': 'job-definition'
                },
                {
                    'name': 'pull-secret',
                    'secret': {
                        'secretName': 'regcred'
                    }
                },
                {
                    'name': 'release-pull-secret',
                    'secret': {
                        'secretName': 'ci-pull-credentials'
                    }
                }
            ]
        }
    }

    return prow_job


def add_machine_os_content_promoter(gendoc, config: Config, major, minor):

    periodics_list = []
    periodics_def = {
        'periodics': periodics_list
    }

    periodics_list.append(_make_promotion_job(major, minor, priv=False))
    periodics_list.append(_make_promotion_job(major, minor, priv=True))

    gendoc.append(periodics_def,
                  comment="""
The RHCOS build pipeline promotes images to the api.ci rhcos namespace into is/machine-os-content. 
In order to validate this image and promote it into the actual CI release payload, this
job runs tests against the machine-os-content image and then promotes it into locations it can be
consumed.
""")
