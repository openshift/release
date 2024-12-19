# BYOH Auto-provisioning Tool

Automates provisioning and management of BYOH Windows worker nodes in OpenShift clusters across multiple cloud providers.

## Prerequisites

- OpenShift Cluster with exported KUBECONFIG
- Terraform ≥ 1.0.0
- `oc` CLI tool
- `jq` for JSON processing

## Supported Platforms

- **AWS**: Automated credential management
- **Azure**: Native cloud integration
- **GCP**: Google Cloud Platform
- **vSphere**: VMware infrastructure
- **Nutanix**: Prism Central managed infrastructure
- **Baremetal**: Non-cloud environments

## Usage

Create BYOH instances:
```bash
./byoh.sh apply <name> <number-of-workers> [suffix] [windows-version]
```

Examples:
```bash
# Create 2 BYOH instances with Windows Server 2019
./byoh.sh apply byoh 2 '' 2019

# Create 4 instances with custom name
./byoh.sh apply my-byoh 4

# Create on Nutanix
./byoh.sh apply ntnx-byoh 2

# Destroy instances
./byoh.sh destroy my-byoh 4
```

### Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| ACTION | Operation (apply/destroy/arguments/configmap/clean) | apply | Yes |
| NAME | Base name for instances | byoh-winc | No |
| NUM_WORKERS | Number of workers | 2 | No |
| FOLDER_SUFFIX | Temporary folder suffix | "" | No |
| WINDOWS_VERSION | Windows Server version (2019/2022) | 2022 | No |

## Cloud Provider Requirements

### AWS
- Credentials in `$HOME/.aws/config` or `$HOME/.aws/credentials`

### Azure
- Valid subscription and service principal

### Nutanix
- Prism Central access
- Pre-configured Windows image
- Configured subnet

### vSphere
- vCenter access
- Network and datastore permissions

## Troubleshooting

Check credentials:
```bash
oc get secret -n kube-system
```

Verify cluster status:
```bash
oc get clusterversion
```

Check cluster capacity:
```bash
oc get nodes
```