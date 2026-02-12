# Pre Upgrade checks

## What this step does ?

1. Creates a VM manifest file and deploy a VM 

2. Run checks to make sure VM deployed correctly

3. Execute SSH checks to make sure VM is accesible and running



## Requirements

1. Container Image with virtctl, sshpass, kubectl available

2. Spoke kubeconfig available in location "<SHARED_DIR/managed-cluster-kubeconfig>"
