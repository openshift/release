#!/usr/bin/env python3

import yaml


CONFIG = {

    'aws-arm64-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 10,
        'us-east-2': 8,
        'us-west-1': 8,
        'us-west-2': 8,
    },
    'aws-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-1-qe-quota-slice': {
        'us-east-1': 5,
    },
    'aws-2-quota-slice': {
        'us-east-1': 40,
        'us-east-2': 40,
        'us-west-1': 35,
        'us-west-2': 40,
    },
    'aws-3-quota-slice': {
        'us-east-1': 40,
    },
    'aws-cspi-qe-quota-slice': {
        'us-east-1': 10,
        'us-east-2': 10,
    },
    'aws-managed-cspi-qe-quota-slice': {
        'us-east-1': 10,
        'us-east-2': 10,
    },
    'aws-qe-quota-slice': {
        'us-east-1': 25,
        'ap-northeast-1': 5,
    },
    'aws-sd-qe-quota-slice': {
        'us-west-2': 3,
    },
    'aws-outpost-quota-slice': {
        'us-east-1': 10,
    },
    'aws-china-qe-quota-slice': {
        'cn-north-1': 1,
        'cn-northwest-1': 1,
    },
    'aws-usgov-qe-quota-slice': {
        'us-gov-west-1': 10,
        'us-gov-east-1': 10,
    },
    'aws-c2s-qe-quota-slice': {
        'us-iso-east-1': 8,
    },
    'aws-sc2s-qe-quota-slice': {
        'us-isob-east-1': 5,
    },
    'aws-interop-qe-quota-slice': {
        'us-east-2': 5,
    },
    'aws-local-zones-quota-slice': {
        'us-east-1': 2,
        'us-west-2': 2
    },
    'aws-perf-qe-quota-slice': {
        'us-west-2': 3,
    },
    'azure4-quota-slice': {
        'centralus': 33,
        'eastus': 8,
        'eastus2': 8,
        'westus': 8
    },
    'azure-2-quota-slice': {
        'centralus': 33,
        'eastus': 8,
        'eastus2': 8,
        'westus': 8
    },
    'azure-arm64-quota-slice': {
        'centralus': 3,
        'eastus': 3,
        'eastus2': 3,
        'westus2': 3
    },
    'azurestack-quota-slice': {
        'ppe3': 2
    },
   'azurestack-qe-quota-slice': {
        'mtcazs': 2
    },
    'azuremag-quota-slice': {
        'usgovvirginia': 5
    },
    'azure-qe-quota-slice': {
        'northcentralus': 10,
        'southcentralus': 10,
        'centralus': 10
    },
    'azure-arm64-qe-quota-slice': {
        'centralus': 6,
        'eastus': 6,
        'eastus2': 4,
        'northeurope': 4
    },
    'azure-marketplace-qe-quota-slice': {
        'westus': 6
    },
    'azuremag-qe-quota-slice': {
        'usgovvirginia': 5,
        'usgovtexas': 5
    },
    'equinix-ocp-metal-quota-slice': {
        'default': 40,
    },
    'equinix-ocp-metal-qe-quota-slice': {
        'default': 40,
    },
    'fleet-manager-qe-quota-slice': {
        'ap-northeast-1': 3,
    },
    'gcp-qe-quota-slice': {
        'us-central1': 30,
    },
    'gcp-quota-slice': {
        'us-central1': 70,
    },
    'gcp-openshift-gce-devel-ci-2-quota-slice': {
        'us-central1': 70,
    },
    'libvirt-s390x-quota-slice': {},
    'libvirt-ppc64le-quota-slice': {},
    'metal-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'default': 1000,
    },
    'nutanix-quota-slice': {},
    'nutanix-qe-quota-slice': {},
    'nutanix-qe-dis-quota-slice': {},
    'openstack-osuosl-quota-slice': {},
    'openstack-quota-slice': {
        'default': 7,
    },
    'openstack-vexxhost-quota-slice': {
        'default': 9,
    },
    'openstack-operators-vexxhost-quota-slice': {
        'default': 2,
    },
    'openstack-hwoffload-quota-slice': {
        'default': 5,
    },
    'openstack-kuryr-quota-slice': {
        'default': 2,
    },
    'openstack-nfv-quota-slice': {
        'default': 5,
    },
    'openstack-vh-mecha-central-quota-slice': {
        'default': 4,
    },
    'openstack-vh-mecha-az0-quota-slice': {
        'default': 2,
    },
    'openstack-ppc64le-quota-slice': {},
    'ovirt-quota-slice': {},
    'ovirt-upgrade-quota-slice': {},
    'ovirt-clusterbot-quota-slice': {
        'default': 3,
    },
    'packet-quota-slice': {
        'default': 60,
    },
    'packet-edge-quota-slice': {
        'default': 50,
    },
    'vsphere-quota-slice':{},
    'vsphere-8-quota-slice':{},
    'vsphere-discon-quota-slice':{},
    'vsphere-dis-quota-slice':{},
    'vsphere-clusterbot-quota-slice':{},
    'vsphere-connected-quota-slice':{},
    'vsphere-multizone-quota-slice':{},
    'vsphere-platform-none-quota-slice':{},
    'osd-ephemeral-quota-slice': {
        'default': 15,
    },
    'aws-osd-msp-quota-slice': {
        'default': 15,
    },
    'aws-cpaas-quota-slice': {
        'us-east-1': 8,
        'us-east-2': 8,
        'us-west-2': 8,
        'eu-west-1': 8,
        'eu-west-2': 8
    },
    'hypershift-quota-slice': {
        'default': 15,
    },
    'powervs-1-quota-slice': {
        'mon01': 1,
        'osa21': 1,
    },
    'powervs-2-quota-slice': {
        'syd04': 1,
        'syd05': 1,
        'tok04': 1
    },
    'ibmcloud-quota-slice': {
        'us-east': 7,
    },
    'ibmcloud-qe-quota-slice': {
        'jp-tok': 10,
    },
    'ibmcloud-multi-ppc64le-quota-slice': {
        'jp-osa': 3,
    },
    'ibmcloud-multi-s390x-quota-slice': {
        'ca-tor': 3,
    },
    'alibabacloud-quota-slice': {
        'us-east-1': 10,
    },
    'alibabacloud-qe-quota-slice': {
        'us-east-1': 10,
    },
    'alibabacloud-cn-qe-quota-slice': {
        'us-east-1': 10,
    },
    'hypershift-hive-quota-slice': {
        'default': 80
    },
    'aws-virtualization-quota-slice': {
        'us-east-1': 5,
        'us-east-2': 5,
        'us-west-1': 5,
        'us-west-2': 5,
    },
    'azure-virtualization-quota-slice': {
        'centralus': 5,
        'eastus': 5,
        'eastus2': 5,
        'westus': 5
    },
    'gcp-virtualization-quota-slice': {
        'us-central1': 50,
    },
    'oci-edge-quota-slice': {
        'default': 50,
    }
}

for i in range(3):
    for j in range(4):
        CONFIG['libvirt-s390x-quota-slice']['libvirt-s390x-{}-{}'.format(i, j)] = 1
# mihawk1 system needs firmware update. We can put it in the list once the firmware is updated and then reserve one cluster back for internal debugging.
for i in range(2):
    for j in range(4):
        CONFIG['libvirt-ppc64le-quota-slice']['libvirt-ppc64le-{}-{}'.format(i+1, j)] = 1
# Reserve one for internal debugging use
# del CONFIG['libvirt-ppc64le-quota-slice']['libvirt-ppc64le-1-3']

for i in range(3):
    CONFIG['nutanix-quota-slice']['nutanix-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-quota-slice']['nutanix-qe-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-dis-quota-slice']['nutanix-qe-dis-segment-{0:0>2}'.format(i)] = 1

for i in range(2):
    CONFIG['openstack-osuosl-quota-slice']['openstack-osuosl-{0:0>2}'.format(i)] = 1

for i in range(4):
    CONFIG['openstack-ppc64le-quota-slice']['openstack-ppc64le-{0:0>2}'.format(i)] = 1

for i in range(10, 15):
    CONFIG['ovirt-quota-slice']['ovirt-{}'.format(i)] = 1

for i in range(1, 7):
    CONFIG['ovirt-upgrade-quota-slice']['ovirt-upgrade-{}'.format(i)] = 1

for i in range(89,93):
    CONFIG['vsphere-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(94,109):
    CONFIG['vsphere-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(56,60):
    CONFIG['vsphere-platform-none-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(60,64):
    CONFIG['vsphere-discon-quota-slice']['qe-discon-segment-{}'.format(i)] = 1

for i in range(230,235):
    CONFIG['vsphere-dis-quota-slice']['devqe-segment-{}-disconnected'.format(i)] = 1

for i in range(50,54):
    CONFIG['vsphere-clusterbot-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(55,56):
    CONFIG['vsphere-connected-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(151,158):
    CONFIG['vsphere-multizone-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(200,204):
    CONFIG['vsphere-8-quota-slice']['ci-segment-{}'.format(i)] = 1
for i in range(205,214):
    CONFIG['vsphere-8-quota-slice']['ci-segment-{}'.format(i)] = 1

config = {
    'resources': [],
}

for typeName, data in sorted(CONFIG.items()):
    resource = {
        'type': typeName,
        'state': 'free',
    }
    if set(data.keys()) == {'default'}:
        resource['min-count'] = resource['max-count'] = data['default']
    else:
        resource['names'] = []
        for name, count in sorted(data.items()):
            if '--' in name:
                raise ValueError('double-dashes are used internally, so {!r} is invalid'.format(name))
            if count > 1:
                width = len(str(count-1))
                resource['names'].extend(['{name}--{typeName}-{i:0>{width}}'.format(name=name,typeName=typeName, i=i, width=width) for i in range(count)])
            else:
                resource['names'].append(name)
    config['resources'].append(resource)

with open('_boskos.yaml', 'w') as f:
    f.write('# generated with generate-boskos.py; do not edit directly\n')
    yaml.dump(config, f, default_flow_style=False)
