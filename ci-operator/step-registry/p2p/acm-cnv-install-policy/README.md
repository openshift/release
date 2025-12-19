# Deploy Policy in ACM hub to install CNV

## What this step does ?

1. Creates a Policy object in ACM that installs the OpenShift Virtualization on selected clusterset

2. Ensures that a ManagedCLusterBinding exist so that ACM can apply policy on targeted clusterset

3. Creates Placement and PlacementBinding to bind CNV installation policy to the correct clusters

4. Waits for CNV installation to complete by vreifying the HyperConverged resource

Installing CNV using a policy ensures that it is installed across clusters that are bound to the clusterset, in this case there's only one cluster

## Requirements

1. A functional ACM hub with governance and Policy frameworks enabled

2. oc and jq installed in the container 

3. Spoke cluster must already be installed and registered with ACM


