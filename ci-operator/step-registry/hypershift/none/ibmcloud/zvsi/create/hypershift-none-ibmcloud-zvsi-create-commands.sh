#!/bin/bash

set -exuo pipefail

infra_name="hypershift-z-$(echo -n $PROW_JOB_ID|cut -c-8)"
rg_name="$infra_name-rg"
ssh_key_name="$infra_name-key"
vpc_name="$infra_name-vpc"
sn_name="$infra_name-sn"
rhel_vsi_name="$infra_name-bastion"
zvsi_name="$infra_name-compute"
hc_name="z-hc-$(echo -n $PROW_JOB_ID|cut -c-8)"
hc_ns="$hc_name-clusters"
dns_name="$infra_name-dns"
dns_zone="$BASE_DOMAIN"
bucket_name="$infra_name"

# Login to the IBM Cloud
echo "Logging into IBM Cloud by targetting the $IC_REGION region"
ibmcloud login --apikey $IC_APIKEY
ibmcloud target -r $IC_REGION
echo "Installing the vpc-infrastructure,cloud-object-storage and cloud-dns-services plugins."
ibmcloud plugin install vpc-infrastructure cloud-object-storage cloud-dns-services

# Create resource group
echo "Creating a resource group in the region $IC_REGION"
ibmcloud resource group-create $rg_name
rg_state=$(ibmcloud resource group $rg_name | awk '/State/{print $2}')
if [ $rg_state != "ACTIVE" ]; then
  echo "Error: Resource Group $rg_name is not created properly."
  exit 1
else 
  echo "Resource Group $rg_name is created successfully in the $IC_REGION region."
fi

# Create SSH key
echo "Creating an SSH key in the resource group $rg_name"
ibmcloud is key-create $ssh_key_name @$HOME/.ssh/id_rsa.pub --resource-group-name $rg_name
key_exists=$(ibmcloud is keys --resource-group-name $rg_name | grep -i $ssh_key_name | wc -l)
if [ $key_exists != "1" ]; then
  echo "Error: SSH Key $ssh_key_name does not exists in the $rg_name resource group."
  exit 1
else 
  echo "SSH Key $ssh_key_name created successfully in the $rg_name resource group."
fi

# Create VPC
echo "Creating a VPC in the resource group $rg_name"
ibmcloud is vpc-create $vpc_name --resource-group-name $rg_name
vpc_status=$(ibmcloud is vpc $vpc_name | awk '/Status/{print $2}')
if [ $vpc_status != "available" ]; then
  echo "Error: VPC $vpc_name is not created properly."
  exit 1
else 
  echo "VPC $vpc_name is created successfully in the $IC_REGION region."
fi
vpc_crn=$(ibmcloud is vpc $vpc_name | awk '/CRN/{print $2}')

# Create subnet
echo "Creating a subnet in the VPC $vpc_name"
ibmcloud is subnet-create $sn_name $vpc_name --ipv4-address-count 16 --zone "$IC_REGION-1" --resource-group-name $rg_name
sn_status=$(ibmcloud is subnet $sn_name | awk '/Status/{print $2}')
if [ $sn_status != "available" ]; then
  echo "Error: Subnet $sn_name is not created properly in the VPC $vpc_name."
  exit 1
else 
  echo "Subnet $sn_name is created successfully in the $vpc_name VPC."
fi
set +e

# Create zVSI custom image
echo "Initaiting the s390x ibmcloud custom image creation for the zVSI compute node."
zvsi_image="rhcos-$ZVSI_IMAGE_VERSION-ibmcloud.s390x.qcow2.gz"
wget -P $HOME/ "https://art-rhcos-ci.s3.amazonaws.com/prod/streams/$OCP_VERSION/builds/$ZVSI_IMAGE_VERSION/s390x/$zvsi_image"
yum install gzip -y
gzip $HOME/$zvsi_image
echo "Creating a service instance $bucket_name-si in the resource group $rg_name."
service_instance_id=$(ibmcloud resource service-instance-create "$bucket_name-si" cloud-object-storage standard global -g $rg_name | awk '/GUID:/{print $2}')
echo "Creating an IAM authorization policy for the service instance."
ibmcloud iam authorization-policy-create is --source-resource-type image cloud-object-storage Reader --target-service-instance-id "$service_instance_id"
echo "Creating a cloud-object-storage(COS) bucket $bucket_name in the service instance $bucket_name-si."
ibmcloud cos create-bucket --bucket $bucket_name --ibm-service-instance-id $service_instance_id
echo "Uploading the $zvsi_image image to the cos bucket $bucket_name."
ibmcloud cos upload --bucket="$bucket_name" --key="$zvsi_image" --file="$HOME/$zvsi_image"
image=${zvsi_image:0:-6} 
zvsi_image_name=${image//[._]/-}
echo "Creating the custom image out of $zvsi_image present in the cos bucket $bucket_name."
zvsi_image_id=$(ibmcloud is image-create $zvsi_image_name --file "cos://$IC_REGION/$bucket_name/$zvsi_image" --os-name $ZVSI_OS --resource-group-name $rg_name | awk '/ID/{print $2}')
sleep 30
image_status=$(ibmcloud is image $zvsi_image_id -q | awk '/Status/{print $2}')
if [ $image_status != "available" ]; then
  echo "Successfully created the zVSI image $zvsi_image_name in the resource group $rg_name."
else 
  echo "Error: Failure in creating the zVSI image $zvsi_image_name using image file present in the $bucket_name."
fi

# Create x86 RHEL VSI to use as bastion
echo "Triggering the $rhel_vsi_name Bastion RHEL VSI creation"
ibmcloud is instance-create $rhel_vsi_name $vpc_name $IC_REGION $RHEL_VSI_PROFILE $sn_name --image $RHEL_VSI_IMAGE --keys $ssh_key_name --resource-group-name $rg_name
rhel_vsi_state=$(ibmcloud is instance $rhel_vsi_name | awk '/Status/{print $2}')
if [ $rhel_vsi_state != "running" ]; then
  echo "Error: Instance $rhel_vsi_name is not created properly in the $vpc_name VPC."
  exit 1
else 
  echo "Instance $rhel_vsi_name is created successfully in the $vpc_name VPC."
fi
nic_name=$(ibmcloud is in-nics $rhel_vsi_name -q | grep -v ID | awk '{print $2}')
echo "Assigning the Floating IP for the bastion"
ibmcloud is in-nic-ipc $rhel_vsi_name $nic_name floating-ip-default-rawhide
rhel_vsi_fip=$(ibmcloud is in-nic-ips $rhel_vsi_name $nic_name -q | grep -v ID | awk '{print $2}')
rhel_vsi_rip=$(ibmcloud is in-nic-rips $rhel_vsi_name $nic_name -q | grep -v ID | awk '{print $3}')

# Configure bastion to host the ignition file
echo "Transferring the management cluster kubeconfig to the bastion - RHEL VSI"
scp $KUBECONFIG root@"$rhel_vsi_fip":~/management-cluster-kubeconfig
if [ $? -eq 0 ]; then
    echo "SUCCESS - Transferred the management cluster kubeconfig to bastion RHEL VSI"
else
    echo "FAILURE - Failed to transfer the management cluster kubeconfig to bastion RHEL VSI"
    exit 1
fi

echo "Configuring bastion with nginx server, oc client"
cat << EOF >> $HOME/bastion.sh
echo "Installing firewalld on bastion - RHEL VSI"
yum install firewalld -y
systemctl start firewalld
systemctl enable firewalld
firewall_add_port=$(firewall-cmd --permanent --add-port={80/tcp,443/tcp} | grep -v Warning)
if [ $firewall_add_port != "success" ]; then
  echo "Error: Adding 80 and 443 TCP ports is not successful to the firewall"
  exit 1
else 
  echo "Added 80 and 443 TCP ports to the firewall successfully"
fi
firewall_reload=$(firewall-cmd --reload)
if [ $firewall_reload != "success" ]; then
  echo "Error: Reloading the firewall after adding the 80,443 tcp ports"
  exit 1
else 
  echo "Firewall reloaded successfullyafter adding the 80,443 tcp ports"
fi

echo "Installing nginx server on bastion - RHEL VSI"
yum install nginx -y
systemctl start nginx
systemctl enable nginx
restart_count=0
while true; do
  nginx_enabled=$(systemctl is-enabled nginx)
  if [ $nginx_enabled != "enabled" && restart_count<6 ]; then
    echo "WARN: NGINX is not enabled yet, restarting the service"
    systemctl restart nginx
    sleep 5
    restart_count+=1
  elif [ $restart_count == 6]; then
    echo "Error: NGINX is not enabled, tried restarting the service 5 times but no luck!!!"
    exit 1
  else 
    echo "NGINX is successfully configured"
    break
  fi
done

echo "Installing wget on bastion - RHEL VSI"
yum install wget -y
is_wget=$(which wget)
if [ $is_wget != "/usr/bin/wget" ]; then
  echo "Error: wget installation is not successful"
  exit 1
else
  echo "wget installation is successful"
fi

echo "Installing oc client on bastion - RHEL VSI"
wget -P $HOME/ https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/$OCP_VERSION/openshift-client-linux-$OCP_VERSION.tar.gz
tar -xvf $HOME/openshift-client-linux-$OCP_VERSION.tar.gz -C /usr/local/bin/
oc_installed_version=$(oc version | awk '/Client Version:/{print $3}')
if [ $oc_installed_version != $OCP_VERSION ]; then
  echo "Error: oc client $oc_installed_version installation is not successful"
  exit 1
else
  echo "oc client $oc_installed_version is installed successfully"
fi

echo "Extracting the hosted cluster kubeconfig"
oc extract -n $hc_ns secret/$hc_name-admin-kubeconfig --kubeconfig=$HOME/management-cluster-kubeconfig --to=- > $HOME/$hc_name-kubeconfig
echo "Extracting the ignition endpoint" 
ignition_endpoint=$(oc get hc $hc_name -n $hc_ns --kubeconfig=$HOME/management-cluster-kubeconfig -o json | jq -r '.status.ignitionEndpoint')
echo "Extracting the ignition token secret"
ignition_token_secret=$(oc get secrets --kubeconfig=$HOME/$hc_name-kubeconfig -n $hc_ns-$hc_name | grep token-$hc_name  | awk '{print $1}')
echo "Extracting the ignitiont token from the secret"
ignition_token=$(oc get secret $ignition_token_secret -o jsonpath={.data.token} --kubeconfig=$HOME/$hc_name-kubeconfig -n $hc_ns-$hc_name )
echo "Fetching the ignition file from the endpoint"
curl -s -k -H "Authorization: Bearer $ignition_token" https://$ignition_endpoint/ignition > /usr/share/nginx/html/zvsi-compute.ign
EOF
ssh root@$rhel_vsi_fip 'bash -s' < $HOME/bastion.sh

# Create zVSI compute node
echo "Triggering the $zvsi_name zVSI creation on IBM Cloud in the VPC $vpc_name"
cat << EOF >> $HOME/$zvsi_name.ign
{"ignition":{"config":{"merge":[{"source":"http://$rhel_vsi_rip:80/zvsi-compute.ign"}]},"version":"3.3.0"}}
EOF
ibmcloud is instance-create $zvsi_name $vpc_name $IC_REGION $ZVSI_PROFILE $sn_name --image $zvsi_image_id --keys $ssh_key_name --resource-group-name $rg_name --user-data @$zvsi_name.ign
zvsi_state=$(ibmcloud is instance $zvsi_name | awk '/Status/{print $2}')
if [ $zvsi_state != "running" ]; then
  echo "Error: Instance $zvsi_name is not created properly in the $vpc_name VPC."
  exit 1
else 
  echo "Instance $zvsi_name is created successfully in the $vpc_name VPC."
fi
nic_name=$(ibmcloud is in-nics $zvsi_name -q | grep -v ID | awk '{print $2}')
echo "Assigning the Floating IP for the zVSI"
ibmcloud is in-nic-ipc $zvsi_name $nic_name floating-ip-default-rawhide
zvsi_fip=$(ibmcloud is in-nic-ips $zvsi_name $nic_name -q | grep -v ID | awk '{print $2}')

# Creating DNS service
echo "Installing the JSON Querier(jq)."
yum install jq -y
echo "Triggering the DNS Service creation on IBM Cloud in the resource group $rg_name"
dns_state=$(ibmcloud dns instance-create $dns_name standard-dns -g $rg_name --output JSON | jq '.state')
if [ $dns_state == "active" ]; then
  echo "$dns_name DNS instance is created successfully and in active state."
else 
  echo "DNS instance $dns_name is not in the active state."
  exit 1
fi

echo "Creating the DNS zone $dns_zone in the instance $dns_name."
dns_zone_id=$(ibmcloud dns zone-create $dns_zone -i $dns_name --output JSON | jq '.id')
if [ -z $dns_zone_id ]; then
  echo "DNS zone $dns_zone is not created properly as it is not possesing any ID."
  exit 1
else 
  echo "DNS zone $dns_zone is created successfully in the instance $dns_name."
fi

echo "Adding VPC network $vpc_name to the DNS zone $dns_zone."
dns_network_state=$(ibmcloud dns permitted-network-add $dns_zone_id --type vpc --vpc-crn $vpc_crn -i $dns_name --output JSON | jq '.state')
if [ $dns_network_state != "ACTIVE" ]; then
  echo "VPC network $vpc_name which is added to the DNS zone $dns_zone is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $vpc_name is successfully added to the DNS zone $dns_zone."
  echo "DNS zone $dns_zone is in the ACTIVE state."
fi

echo "Adding an A record in the DNS zone $dns_zone to resolve the hosted cluster console to the zVSI compute node IP."
ibmcloud dns resource-record-create $dns_zone_id --type A --name "*.apps.$hc_name.$dns_zone" --ipv4 $zvsi_fip -i $dns_name
if [ $? -eq 1 ]; then
  echo "Successfully added the A record of zVSI compute node IP to resolve the hosted cluster apis."
else 
  echo "A record addition is not successful."
fi

# Checking if the compute node is attached
echo "Checking if the $zvsi_name compute node is attached to the hosted control plane"
echo "Extracting the hosted cluster kubeconfig"
oc extract -n $hc_ns secret/$hc_name-admin-kubeconfig --kubeconfig=$KUBECONFIG --to=- > $HOME/$hc_name-kubeconfig
csr_count=0
while true; do
  compute_status=$(oc get no $zvsi_name --kubeconfig=$HOME/$hc_name-kubeconfig --no-headers=true | awk '{print $2}')
  if [ compute_status != "Ready" ] && [ csr_count<20 ]; then
    oc get csr --kubeconfig=$hc_name-kubeconfig -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve --kubeconfig=$HOME/$hc_name-kubeconfig
    csr_count+=1
    sleep 30
  elif [ csr_count==20 ]; then
    echo "Error: $zvsi_name compute node is not in ready state, already tried signing the csr 20 times in 30 seconds interval but no luck!!!"
    exit 1
  else
    echo "$zvsi_name compute node is in ready state and attached to the hosted control plane"
    break
  fi
done

# Checking if cluster operators are in true state
echo "Checking the cluster operators status in the hosted control plane"
co_names=$(oc get co --kubeconfig=$hc_name-kubeconfig | grep -v NAME | awk '{print $1}')
co_false_list=()
for co in "${co_names[@]}"; do
  co_status=$(oc get co $co --kubeconfig=$hc_name-kubeconfig --no-headers=true | awk '{print $3}')
  if [ $co_status == "False" ]; then
    co_false_list+=("$co")
  fi
done
if [ -n "$co_false_list" ]; then
  echo "Error: $co_false_list are in False state and not available"
else 
  echo "All the cluster operators are in True state and are available"
fi

# Checking if the hosted cluster is in complete state
echo "Checking the Hosted Cluster status"
hc_status=$(oc get hc $hc_name -n $clusters_name --kubeconfig=$KUBECONFIG --no-headers=true | awk '{print $3}')
if [ $hc_status != "Completed" ]; then
  echo "Error: Hosted Cluster $hc_name is not in completed state"
  exit 1
else 
  echo "Hosted Cluster $hc_name is in completed state and available"
fi
set +e