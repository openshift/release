#!/usr/bin/env python3

import yaml


CONFIG = {

    'aws-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-1-qe-quota-slice': {
        'us-east-1': 10,
    },
    'aws-2-quota-slice': {
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-3-quota-slice': {
        'us-east-1': 50,
        'us-east-2': 10,
        'us-west-1': 35,
        'us-west-2': 25,
    },
    'aws-4-quota-slice': {
        'us-east-1': 50,
        'us-east-2': 4,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-5-quota-slice': {
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-cspi-qe-quota-slice': {
        'us-east-2': 30,
        'us-west-2': 30,
    },
    'aws-managed-cspi-qe-quota-slice': {
        'us-east-1': 10,
        'us-east-2': 10,
    },
    'aws-qe-quota-slice': {
        'us-east-1': 30,
        'ap-northeast-1': 15,
    },
    'aws-autorelease-qe-quota-slice': {
        'us-east-1': 7,
    },
    'aws-terraform-qe-quota-slice': {
        'ap-northeast-1': 2,
        'us-east-1': 2,
        'us-east-2': 2,
    },
    'aws-sd-qe-quota-slice': {
        'us-west-2': 10,
    },
    'aws-outpost-quota-slice': {
        'us-east-1': 10,
    },
    'aws-outpost-qe-quota-slice': {
        'us-east-1': 5,
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
    'aws-edge-zones-quota-slice': {
        'us-east-1': 10,
        'us-west-2': 10,
    },
    'aws-splat-quota-slice': {
        'us-east-1': 5,
        'us-west-2': 5
    },
    'aws-perfscale-qe-quota-slice': {
        'us-west-2': 20,
    },
    'metal-perfscale-cpt-quota-slice': {
        'metal-perfscale-cpt-rdu3': 1,
    },
    'metal-perfscale-jetlag-quota-slice': {
        'metal-perfscale-jetlag-rdu3': 1,
    },
    'metal-perfscale-osp-quota-slice': {
        'metal-perfscale-osp-rdu2': 1,
    },
    'metal-perfscale-selfsched-quota-slice': {
        'metal-perfscale-selfsched': 3,
    },
    'metal-perfscale-telco-quota-slice': {
        'metal-perfscale-telco-rdu2': 1,
    },
    'aws-restricted-qe-quota-slice': {
        'us-east-1': 5,
        'ap-northeast-1': 5,
    },
    'aws-perfscale-lrc-qe-quota-slice': {
        'us-west-2': 5,
    },
    'aws-serverless-quota-slice': {
        'us-east-1': 5,
        'us-east-2': 5,
    },
    'aws-sustaining-autorelease-412-quota-slice': {
        # We can re-configure later as per requirement
        'us-east-1': 60,
    },
    'aws-rhtap-qe-quota-slice': {
        'us-east-1': 10
    },
    'aws-konflux-qe-quota-slice': {
        'us-west-2': 10
    },
    'aws-rhtap-performance-quota-slice': {
        'eu-west-1': 10
    },
    'aws-pipelines-performance-quota-slice': {
        'eu-west-1': 10
    },
    'aws-rhdh-performance-quota-slice': {
        'eu-west-1': 10
    },
    'aws-opendatahub-quota-slice': {
        # Wild guesses. We can re-configure later
        # https://docs.ci.openshift.org/docs/architecture/quota-and-leases/#adding-a-new-type-of-resource
        'us-east-1': 40,
        'us-east-2': 40,
        'us-west-1': 40,
        'us-west-2': 40,
    },
    'aws-telco-quota-slice': {
        # Wild guesses. We can re-configure later
        # https://docs.ci.openshift.org/docs/architecture/quota-and-leases/#adding-a-new-type-of-resource
        'us-east-1': 60,
        'us-east-2': 60,
        'us-west-1': 60,
        'us-west-2': 60,
    },
    'aws-confidential-qe-quota-slice': {
        'us-east-2': 6,
    },
    'aws-devfile-quota-slice': {
        'us-west-2': 10
    },
    'aws-mco-qe-quota-slice': {
        'us-east-1': 10,
        'us-east-2': 10,
        'us-west-1': 10,
        'us-west-2': 10,
    },
    'azure4-quota-slice': {
        'centralus': 14,
        'eastus': 14,
        'eastus2': 14,
        'westus': 14
    },
    'azure-2-quota-slice': {
        'centralus': 33,
        'eastus': 33,
        'eastus2': 33,
        'westus': 33
    },
    'azure-arm64-quota-slice': {
        'centralus': 33,
        'southcentralus': 8,
        'eastus': 8,
        'westus2': 8
    },
    'azure-perfscale-quota-slice': {
        'northcentralus': 10,
        'southcentralus': 10,
        'centralus': 10
    },
    'azurestack-quota-slice': {
        'ppe3': 2
    },
    'azurestack-dev-quota-slice': {
        'mtcazs': 4
    },
    'azurestack-qe-quota-slice': {
        'mtcazs': 4
    },
    'azuremag-quota-slice': {
        'usgovvirginia': 5
    },
    'azure-qe-quota-slice': {
        'northcentralus': 10,
        'westus2': 10,
        'centralus': 10
    },
    'azure-observability-quota-slice': {
        'westus': 3
    },
    'azure-hcp-qe-quota-slice': {
        'westus': 5,
        'eastus': 5,
        'uksouth': 5,
        'westeurope': 5,
    },
    'azure-hcp-ha-qe-quota-slice': {
        'westus2': 5,
        'southcentralus': 5,
        'eastasia': 5,
        'canadacentral': 5,
    },
    'azure-autorelease-qe-quota-slice': {
        'eastus2': 7
    },
    'azure-arm64-qe-quota-slice': {
        'centralus': 6,
        'eastus': 6,
        'eastus2': 4,
        'northeurope': 4
    },
    'azuremag-qe-quota-slice': {
        'usgovvirginia': 5,
        'usgovtexas': 5
    },
    'azure-sustaining-autorelease-412-quota-slice': {
        'eastus': 60,
    },
    'azure-confidential-qe-quota-slice': {
        'eastus': 6,
    },
    'aro-hcp-int-quota-slice': {
        'default': 1,
    },
    'aro-hcp-stg-quota-slice': {
        'default': 3,
    },
    'aro-hcp-prod-quota-slice': {
        'default': 7,
    },
    'aro-hcp-dev-quota-slice': {
        'default': 10,
    },
    'aro-hcp-test-tenant-quota-slice': {
        'default': 10,
    },
    'aro-hcp-test-msi-containers-dev': {},
    'aro-hcp-test-msi-containers-int': {},
    'aro-hcp-test-msi-containers-stg': {},
    'aro-hcp-test-msi-containers-prod': {},
    'equinix-ocp-metal-quota-slice': {
        'default': 140,
    },
    'equinix-ocp-metal-qe-quota-slice': {
        'default': 40,
    },
    'aws-sandboxed-containers-operator-quota-slice': {
        'us-east-2': 10,
    },
    'oex-aws-qe-quota-slice': {
        'default': 40,
    },
    'hyperfleet-e2e-quota-slice': {
        'default': 20,
    },
    'equinix-ocp-hcp-quota-slice': {
        'default': 20,
    },
    'equinix-edge-enablement-quota-slice': {
        'default': 40,
    },
    'fleet-manager-qe-quota-slice': {
        'ap-northeast-1': 3,
    },
    'gcp-qe-quota-slice': {
        'us-central1': 30,
    },
    'gcp-observability-quota-slice': {
        'us-central1': 30,
    },
    'gcp-qe-c3-metal-quota-slice': {
        'us-central1': 4,
    },
    'gcp-autorelease-qe-quota-slice': {
        'us-central1': 7,
    },
    'gcp-confidential-qe-quota-slice': {
        'us-central1': 6,
    },
    'gcp-sustaining-autorelease-412-quota-slice': {
        'us-east1': 60,
    },
    'gcp-quota-slice': {
        'us-central1': 70,
    },
    'gcp-3-quota-slice': {
        'us-central1': 70,
    },
    'gcp-openshift-gce-devel-ci-2-quota-slice': {
        'us-central1': 70,
    },
    'gcp-arm64-quota-slice': {
        'us-central1': 30,
    },
    'gcp-opendatahub-quota-slice': {
        'us-central1': 30,
    },
    'gcp-telco-quota-slice': {
        'us-central1': 40,
    },
    'libvirt-s390x-1-quota-slice': {},
    'libvirt-s390x-2-quota-slice': {},
    'libvirt-s390x-amd64-quota-slice': {
        'libvirt-s390x-amd64-0-0': 1
    },
    'libvirt-s390x-vpn-quota-slice': {
        'libvirt-s390x-0-1': 1
    },
    'libvirt-ppc64le-s2s-quota-slice':{},
    'metal-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'default': 1000,
    },
    'nutanix-quota-slice': {},
    'nutanix-qe-quota-slice': {},
    'nutanix-qe-dis-quota-slice': {},
    'nutanix-qe-zone-quota-slice': {},
    'nutanix-qe-gpu-quota-slice': {},
    'nutanix-qe-flow-quota-slice': {},
    'openstack-osuosl-quota-slice': {},
    'openstack-vexxhost-quota-slice': {
        # 3 * 512GB RAM, 96 cores (with 4x overcommit) hosts
        'default': 15,
    },
    'openstack-operators-vexxhost-quota-slice': {
        'default': 2,
    },
    'openstack-hwoffload-quota-slice': {
        'default': 3,
    },
    'openstack-nerc-dev-quota-slice': {
        'default': 1,
    },
    'openstack-rhoso-quota-slice': {
        'serval71.lab.eng.tlv2.redhat.com': 1,
    },
    'openstack-rhos-ci-quota-slice': {
        'default': 1,
    },
    'openstack-nfv-quota-slice': {
        'default': 4,
    },
    'openstack-vh-mecha-central-quota-slice': {
        'default': 3,
    },
    'openstack-vh-mecha-az0-quota-slice': {
        'default': 3,
    },
    'openstack-vh-bm-rhos-quota-slice': {
        'openstack-vh-mecha-central': 3,
        'openstack-vh-mecha-az0': 3,
        'openstack-hwoffload': 3,
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
    'vsphere-dis-2-quota-slice':{},
    'vsphere-connected-2-quota-slice':{},
    'vsphere-multizone-2-quota-slice':{},
    'vsphere-elastic-quota-slice':{},
    'vsphere-elastic-poc-quota-slice':{},
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
        'default': 50,
    },
    'powervc-1-quota-slice': {
        'default': 4,
    },
    'powervs-1-quota-slice': {
        'mon01': 1,
        'osa21': 1,
    },
    'powervs-2-quota-slice': {
        'syd04': 1,
        'syd05': 1,
    },
    'powervs-3-quota-slice': {
        'dal10': 1,
    },
    'powervs-4-quota-slice': {
        'wdc06': 1,
    },
    'powervs-5-quota-slice': {},
    'powervs-6-quota-slice': {},
    'powervs-7-quota-slice': {},
    'powervs-8-quota-slice': {},
    'powervs-multi-1-quota-slice': {
        'wdc06': 2,
    },
    'ibmcloud-cspi-qe-quota-slice': {
        'us-east': 40,
    },
    'ibmcloud-quota-slice': {
        'us-east': 7,
    },
    'ibmcloud-qe-quota-slice': {
        'jp-tok': 20,
    },
    'ibmcloud-qe-2-quota-slice': {
        'us-east': 10,
    },
    'ibmcloud-gpu-quota-slice': {
        'us-east': 10,
    },
    'ibmcloud-multi-ppc64le-quota-slice': {
        'us-east': 3,
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
        'default': 10,
    },
    'aws-virtualization-quota-slice': {
        'us-east-1': 5,
        'us-east-2': 5,
        'us-west-1': 5,
        'us-west-2': 5,
    },
    'azure-virtualization-quota-slice': {
        'eastus': 10,
        'eastus2': 10,
        'westus': 10
    },
    'gcp-virtualization-quota-slice': {
        'us-central1': 50,
    },
    'oci-agent-qe-quota-slice': {
        'default': 50,
    },
    'oci-edge-quota-slice': {
        'default': 50,
    },
    'aws-perfscale-quota-slice': {
        'us-west-2': 10,
    },
    'aws-perfscale-okd-quota-slice': {
        'us-east-1': 1,
    },
    'aws-stackrox-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-chaos-quota-slice': {
        'us-west-2': 10,
    },
    'gcp-chaos-quota-slice': {
        'us-central1': 10,
    },
    'aws-kubevirt-quota-slice': {
        'us-east-2': 10,
    },
    'hypershift-powervs-quota-slice': {
        'default': 3,
    },
    'hypershift-powervs-cb-quota-slice': {
        'default': 5,
    },
    'ossm-aws-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 50,
        'us-east-2': 50,
        'us-west-2': 50,
    },
    'medik8s-aws-quota-slice': {
        'us-east-1': 15,
        'us-east-2': 15,
        'us-west-2': 15,
    },
    'gitops-aws-quota-slice': {
        'us-west-2': 10
    },
    'che-aws-quota-slice': {
        # us-east-2 is reserved for the air-gapped clusters
        'us-east-1': 10,
        'us-west-1': 10,
    },
    'osl-gcp-quota-slice': {
        'us-central1': 10,
    },
    'devsandboxci-aws-quota-slice': {
        # Wild guesses.
        'us-east-1': 20,
        'us-east-2': 20,
    },
    'quay-aws-quota-slice': {
        'us-east-1': 20,
        'us-west-1': 20,
    },
    'aws-quay-qe-quota-slice': {
        'us-east-1': 30,
        'us-east-2': 30,
        'us-west-1': 30,
        'us-west-2': 30,
    },
    'gcp-quay-qe-quota-slice': {
        'us-central1': 30,
    },
    'azure-quay-qe-quota-slice': {
        'northcentralus': 10,
        'westus2': 10,
        'centralus': 10
    },
    'aws-edge-infra-quota-slice': {
        'us-east-1': 5,
        'us-east-2': 5,
        'us-west-1': 5,
        'us-west-2': 5,
    },
    'rh-openshift-ecosystem-quota-slice': {
        'us-east-1': 10,
        'us-east-2': 10,
        'us-west-1': 10,
        'us-west-2': 10,
    },
    'odf-aws-quota-slice': {
        'us-east-1': 25,
        'us-east-2': 25,
        'us-west-1': 25,
        'us-west-2': 25,
    },
    'aws-ip-pools-us-east-1': {
        'default': 256,
    },
    'aws-observability-quota-slice': {
        'us-east-1': 25,
        'us-east-2': 25,
    },
    'aro-redhat-tenant-quota-slice': {
        'default': 1,
    },
    'aws-ovn-perfscale-quota-slice': {
        'us-east-1': 4,
    },
    'aws-rhoai-qe-quota-slice': {
        'us-east-1': 30,
        'us-east-2': 30,
    },
    'aws-managed-rosa-rhoai-qe-quota-slice': {
        'us-east-1': 30,
        'us-east-2': 30,
    },
    'aws-managed-osd-rhoai-qe-quota-slice': {
        'us-east-1': 30,
        'us-east-2': 30,
    },
    'ibmcloud-rhoai-qe-quota-slice': {
        'us-east': 40,
    },
    'aws-oadp-qe-quota-slice': {
        'us-east-1': 15,
        'us-east-2': 15,
    },
    'azure-oadp-qe-quota-slice': {
        'centralus': 10,
        'eastus': 10,
        'eastus2': 10,
    },
    'aws-lp-chaos-quota-slice': {
        'us-west-2': 10,
    },
    'metal-redhat-gs-quota-slice': {
        'default': 1,
    },
}

for i in range(2,7):
    for j in range(2):
        CONFIG['libvirt-s390x-{}-quota-slice'.format(j+1)]['libvirt-s390x-{}-{}'.format(i, j)] = 1
for i in range(3):
    for j in range(4):
        CONFIG['libvirt-ppc64le-s2s-quota-slice']['libvirt-ppc64le-s2s-{}-{}'.format(i, j)] = 1
for i in range(3):
    CONFIG['nutanix-quota-slice']['nutanix-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-quota-slice']['nutanix-qe-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-dis-quota-slice']['nutanix-qe-dis-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-zone-quota-slice']['nutanix-qe-zone-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-gpu-quota-slice']['nutanix-qe-gpu-segment-{0:0>2}'.format(i)] = 1

for i in range(3):
    CONFIG['nutanix-qe-flow-quota-slice']['nutanix-qe-flow-segment-{0:0>2}'.format(i)] = 1

for i in range(2):
    CONFIG['openstack-osuosl-quota-slice']['openstack-osuosl-{0:0>2}'.format(i)] = 1

for i in range(4):
    CONFIG['openstack-ppc64le-quota-slice']['openstack-ppc64le-{0:0>2}'.format(i)] = 1

for i in range(10, 15):
    CONFIG['ovirt-quota-slice']['ovirt-{}'.format(i)] = 1

for i in range(1, 7):
    CONFIG['ovirt-upgrade-quota-slice']['ovirt-upgrade-{}'.format(i)] = 1

for i in [990,1169,1166,1164,1146]:
    CONFIG['vsphere-dis-2-quota-slice']['bcr01a.dal12.{}'.format(i)] = 1

for i in [871,991,1165,1154,1148,1140]:
    CONFIG['vsphere-connected-2-quota-slice']['bcr01a.dal12.{}'.format(i)] = 1

for i in [1287,1289,1296,1298,1300,1302]:
    CONFIG['vsphere-multizone-2-quota-slice']['bcr03a.dal10.{}'.format(i)] = 1

for i in range(0,2):
    CONFIG['vsphere-elastic-poc-quota-slice']['vsphere-elastic-poc-{}'.format(i)] = 1

for i in range(0,80):
    CONFIG['vsphere-elastic-quota-slice']['vsphere-elastic-{}'.format(i)] = 1

for i in range(4):
    CONFIG['powervs-5-quota-slice']['mad02-powervs-5-quota-slice-{}'.format(i)] = 1

for i in range(4):
    CONFIG['powervs-6-quota-slice']['lon04-powervs-6-quota-slice-{}'.format(i)] = 1

for i in range(4):
    CONFIG['powervs-7-quota-slice']['lon06-powervs-7-quota-slice-{}'.format(i)] = 1

for i in range(2):
    CONFIG['powervs-8-quota-slice']['fran-powervs-8-quota-slice-{}'.format(i)] = 1

for i in range(120):
    CONFIG['aro-hcp-test-msi-containers-dev']['aro-hcp-test-msi-containers-dev-{}'.format(i)] = 1
    CONFIG['aro-hcp-test-msi-containers-int']['aro-hcp-test-msi-containers-int-{}'.format(i)] = 1
    CONFIG['aro-hcp-test-msi-containers-stg']['aro-hcp-test-msi-containers-stg-{}'.format(i)] = 1
    CONFIG['aro-hcp-test-msi-containers-prod']['aro-hcp-test-msi-containers-prod-{}'.format(i)] = 1



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
