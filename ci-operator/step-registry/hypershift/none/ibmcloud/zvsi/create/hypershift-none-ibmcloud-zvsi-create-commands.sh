#!/bin/bash

set -xuo pipefail

infra_name="hcp-s390x-$(echo -n $PROW_JOB_ID|cut -c-8)"
rg_name="$infra_name-rg"
ssh_key_name="$infra_name-key"
vpc_name="$infra_name-vpc"
sn_name="$infra_name-sn"
rhel_vsi_name="$infra_name-bastion"
zvsi_name="$infra_name-compute"
hc_name="hc-$(echo -n $PROW_JOB_ID|cut -c-8)"
hc_ns="hcp-s390x"
dns_name="$infra_name-dns"
dns_zone="$BASE_DOMAIN"
bucket_name="$infra_name"
plugins_list=("vpc-infrastructure" "cloud-object-storage" "cloud-dns-services")

# Installing CLI tools
set -e
echo "Installing wget and jq (JSON Querier)"
yum install -y wget jq
set +e
echo "Checking if ibmcloud CLI is installed."
ibmcloud -v
if [ $? -eq 0 ]; then
  echo "ibmcloud CLI is already installed."
else
  set -e
  echo "ibmcloud CLI is not installed. Installing it now..."
  wget -P $HOME/ https://download.clis.cloud.ibm.com/ibm-cloud-cli/$IBMCLOUD_CLI_VERSION/binaries/IBM_Cloud_CLI_${IBMCLOUD_CLI_VERSION}_linux_amd64.tgz
  tar -xvf $HOME/IBM_Cloud_CLI_${IBMCLOUD_CLI_VERSION}_linux_amd64.tgz
  cp $HOME/IBM_Cloud_CLI/ibmcloud /usr/bin/
fi 

# Login to the IBM Cloud
set -e
echo "Logging into IBM Cloud by targetting the $IC_REGION region"
ibmcloud login --apikey $IC_APIKEY -r $IC_REGION
set +e
echo "Checking if the $plugins_list plugins are installed."
for plugin in "${plugins_list[@]}"; do  
  ibmcloud plugin list -q | grep $plugin
  if [ $? -ne 0 ]; then
    echo "$plugin plugin is not installed. Installing it now..."
    ibmcloud plugin install $plugin -f
    echo "$plugin plugin is installed successfully."
  else 
    echo "$plugin plugin is already installed."
  fi
done

# Create resource group
set -e
echo "Creating a resource group in the region $IC_REGION"
ibmcloud resource group-create $rg_name
rg_state=$(ibmcloud resource group $rg_name | awk '/State/{print $2}')
set +e
if [ "$rg_state" != "ACTIVE" ]; then
  echo "Error: Resource Group $rg_name is not created properly."
  exit 1
else 
  echo "Resource Group $rg_name is created successfully and is in active state in the $IC_REGION region."
fi

# Create SSH key
set -e
echo "Creating an SSH key in the resource group $rg_name"
ibmcloud is key-create $ssh_key_name @$HOME/.ssh/id_rsa.pub --resource-group-name $rg_name
ibmcloud is keys --resource-group-name $rg_name | grep -i $ssh_key_name
set +e

# Create VPC
set -e
echo "Creating a VPC in the resource group $rg_name"
ibmcloud is vpc-create $vpc_name --resource-group-name $rg_name
set +e
vpc_status=$(ibmcloud is vpc $vpc_name | awk '/Status/{print $2}')
if [ "$vpc_status" != "available" ]; then
  echo "Error: VPC $vpc_name is not created properly."
  exit 1
else 
  echo "VPC $vpc_name is created successfully in the $IC_REGION region."
fi
vpc_crn=$(ibmcloud is vpc $vpc_name | awk '/CRN/{print $2}')

# Create subnet
set -e
echo "Creating a subnet in the VPC $vpc_name"
ibmcloud is subnet-create $sn_name $vpc_name --ipv4-address-count 16 --zone "$IC_REGION-1" --resource-group-name $rg_name
sn_status=$(ibmcloud is subnet $sn_name | awk '/Status/{print $2}')
set +e
if [ "$sn_status" != "available" ]; then
  echo "Error: Subnet $sn_name is not created properly in the VPC $vpc_name."
  exit 1
else 
  echo "Subnet $sn_name is created successfully in the $vpc_name VPC."
fi

# Create x86 RHEL VSI to use as bastion
set -e
echo "Triggering the $rhel_vsi_name Bastion RHEL VSI creation"
ibmcloud is instance-create $rhel_vsi_name $vpc_name $IC_REGION-1 $RHEL_VSI_PROFILE $sn_name --image $RHEL_VSI_IMAGE --keys $ssh_key_name --resource-group-name $rg_name
set +e
sleep 60
rhel_vsi_state=$(ibmcloud is instance $rhel_vsi_name | awk '/Status/{print $2}')
if [ "$rhel_vsi_state" != "running" ]; then
  echo "Error: Instance $rhel_vsi_name is not created properly in the $vpc_name VPC."
  exit 1
else 
  echo "Instance $rhel_vsi_name is created successfully in the $vpc_name VPC."
fi
sg_name=$(ibmcloud is instance $rhel_vsi_name --output JSON | jq -r '.network_interfaces|.[].security_groups|.[].name')
echo "Adding an inbound rule in the $rhel_vsi_name instance security group for ssh and scp."
ibmcloud is sg-rulec $sg_name inbound tcp --port-min 22 --port-max 22
if [ $? -eq 0 ]; then
    echo "Successfully added the inbound rule."
else
    echo "Failure while adding the inbound rule to the $rhel_vsi_name instance security group."
    exit 1
fi  
nic_name=$(ibmcloud is in-nics $rhel_vsi_name -q | grep -v ID | awk '{print $2}')
echo "Creating a Floating IP for the bastion"
rhel_vsi_fip=$(ibmcloud is ipc $rhel_vsi_name-ip --zone $IC_REGION-1 --resource-group-name $rg_name | awk '/Address/{print $2}')
echo "Assigning the Floating IP for the bastion"
rhel_vsi_fip_status=$(ibmcloud is in-nic-ipc $rhel_vsi_name $nic_name $rhel_vsi_name-ip | awk '/Status/{print $2}')
if [ "$rhel_vsi_fip_status" != "available" ]; then
  echo "Error: Floating IP $rhel_vsi_name-ip is not assigned to the $rhel_vsi_name instance."
  exit 1
else 
  echo "Floating IP $rhel_vsi_name-ip is successfully assigned to the $rhel_vsi_name instance."
fi
rhel_vsi_rip=$(ibmcloud is in-nic-rips $rhel_vsi_name $nic_name -q | grep -v ID | awk '{print $3}')

# Configure bastion to host the ignition file
set -e
cluster_api_url=$(cat $KUBECONFIG | awk '/server:/{print$2}')
echo "Logging into the management cluster"
oc login $cluster_api_url -u kubeadmin -p $KUBEADMIN_PASSWORD
echo "Extracting the hosted cluster kubeconfig"
oc extract -n $hc_ns secret/$hc_name-admin-kubeconfig --kubeconfig=$KUBECONFIG --to=- > $HOME/$hc_name-kubeconfig
echo "Extracting the ignition endpoint" 
ignition_endpoint=$(oc get hc $hc_name -n $hc_ns --kubeconfig=$KUBECONFIG -o json | jq -r '.status.ignitionEndpoint')
echo "Extracting the ignition token secret"
ignition_token_secret=$(oc get secrets --kubeconfig=$KUBECONFIG -n $hc_ns-$hc_name | grep token-$hc_name  | awk '{print $1}')
echo "Extracting the ignition token from the secret"
ignition_token=$(oc get secret $ignition_token_secret -o jsonpath={.data.token} --kubeconfig=$KUBECONFIG -n $hc_ns-$hc_name )
set +e

echo "Exporting the ignition variables to bastion - RHEL VSI"
cat << EOF >> $HOME/ignition-vars
token=$ignition_token
endpoint=$ignition_endpoint
EOF
scp -o StrictHostKeyChecking=no $HOME/ignition-vars root@"$rhel_vsi_fip":~/ignition-vars
if [ $? -eq 0 ]; then
    echo "SUCCESS - Exported the ignition variables successfully to bastion."
    rm -rf $HOME/ignition-vars
else
    echo "FAILURE - Failed to export the ignition variables to bastion RHEL VSI."
    exit 1
fi

echo "Configuring bastion with nginx server, oc client"
cat << 'EOF' >$HOME/bastion.sh
set -e
source $HOME/ignition-vars
echo "Installing firewalld on bastion - RHEL VSI"
yum install firewalld -y
systemctl start firewalld
systemctl enable firewalld
set +e
firewall_add_port=$(firewall-cmd --permanent --add-port={80/tcp,443/tcp} | grep -v Warning)
if [ "$firewall_add_port" != "success" ]; then
  echo "Error: Adding 80 and 443 TCP ports is not successful to the firewall"
  exit 1
else 
  echo "Added 80 and 443 TCP ports to the firewall successfully"
fi
firewall_reload=$(firewall-cmd --reload)
if [ "$firewall_reload" != "success" ]; then
  echo "Error: Reloading the firewall after adding the 80,443 tcp ports"
  exit 1
else 
  echo "Firewall reloaded successfully after adding the 80,443 tcp ports"
fi

set -e
echo "Installing nginx server on bastion - RHEL VSI"
yum install nginx -y
systemctl start nginx
set +e
systemctl enable nginx
restart_count=1
while true; do
  nginx_enabled=$(systemctl is-enabled nginx)
  if [ "$nginx_enabled" != "enabled" ] && [ $restart_count -lt 10 ]; then
    echo "WARN-$restart_count: NGINX is not enabled yet, restarting the service"
    systemctl restart nginx
    sleep 6
    restart_count=$((restart_count+1))
  elif [ "$nginx_enabled" != "enabled" ] && [ $restart_count -eq 10 ]; then
    echo "Error: NGINX is not enabled properly, tried restarting the service $restart_count times but no luck!!!"
    exit 1
  else 
    echo "NGINX is configured successfully."
    break
  fi
done

set -e
echo "Fetching the ignition file from the endpoint"
curl -s -k -H "Authorization: Bearer $token" https://$endpoint/ignition > /usr/share/nginx/html/zvsi-compute.ign
chmod 644 /usr/share/nginx/html/zvsi-compute.ign
echo "Successfully fetched the ignition file into bastion."
set +e
EOF

ssh -o StrictHostKeyChecking=no root@$rhel_vsi_fip 'bash -s' < $HOME/bastion.sh
if [ $? -eq 0 ]; then
    echo "SUCCESS - Configured the RHEL VSI Bastion successfully"
    rm -rf $HOME/bastion.sh
else
    echo "FAILURE - Failed to configure the RHEL VSI bastion completely."
    exit 1
fi

# Create ibmcloud zVSI custom image
set -e
echo "Initiating the s390x ibmcloud custom image creation for the zVSI compute node."
zvsi_image="rhcos-$ZVSI_IMAGE_VERSION-ibmcloud.s390x.qcow2"
wget -P $HOME/ "https://art-rhcos-ci.s3.amazonaws.com/prod/streams/$OCP_VERSION/builds/$ZVSI_IMAGE_VERSION/s390x/$zvsi_image.gz"
yum install gzip -y
gzip -vdf $HOME/$zvsi_image.gz
echo "Creating a service instance $bucket_name-si in the resource group $rg_name."
service_instance_id=$(ibmcloud resource service-instance-create "$bucket_name-si" cloud-object-storage standard global -g $rg_name | awk '/GUID:/{print $2}')
echo "Creating an IAM authorization policy for the service instance."
ibmcloud iam authorization-policy-create is --source-resource-type image cloud-object-storage Reader --target-service-instance-id "$service_instance_id"
echo "Creating a cloud-object-storage(COS) bucket $bucket_name in the service instance $bucket_name-si."
ibmcloud cos create-bucket --bucket $bucket_name --ibm-service-instance-id $service_instance_id
echo "Uploading the $zvsi_image image to the cos bucket $bucket_name."
ibmcloud cos upload --bucket="$bucket_name" --key="$zvsi_image" --file="$HOME/$zvsi_image"
zvsi_image_name=${zvsi_image//[._]/-}
set +e
echo "Creating the custom image out of $zvsi_image present in the cos bucket $bucket_name."
zvsi_image_id=$(ibmcloud is image-create $zvsi_image_name --file "cos://$IC_REGION/$bucket_name/$zvsi_image" --os-name $ZVSI_OS --resource-group-name $rg_name | awk '/ID/{print $2}')
image_count=1
while true; do
  image_status=$(ibmcloud is image $zvsi_image_id -q | awk '/Status/{print $2}')
  echo "Checking the image status if it is ready to use"
  if [ "$image_status" != "available" ] && [ $image_count -lt 10 ] ; then
    echo "Check-$image_count: Image status is not ready yet, checking again after 30 seconds..."
    sleep 30
    image_count=$((image_count+1))
  elif [ "$image_status" != "available" ] && [ $image_count -eq 10 ]; then
    echo "Error: Failure in creating the zVSI image $zvsi_image_name as it is not available to use yet."
    echo "Already tried checking the image status $image_count times in 30 seconds interval but still not ready to use!!!"
    exit 1
  else
    echo "Check-$image_count: Image status is ready to use."
    echo "$zvsi_image_name Image is created successfully in the resource group $rg_name."
    rm -rf $HOME/$zvsi_image
    break
  fi
done

# Create zVSI compute node
set -e
echo "Triggering the $zvsi_name zVSI creation on IBM Cloud in the VPC $vpc_name"
cat << EOF >> ./$zvsi_name.ign
{"ignition":{"config":{"merge":[{"source":"http://$rhel_vsi_rip:80/zvsi-compute.ign"}]},"version":"3.3.0"}}
EOF
ibmcloud is instance-create $zvsi_name $vpc_name $IC_REGION-1 $ZVSI_PROFILE $sn_name --image $zvsi_image_id --keys $ssh_key_name --resource-group-name $rg_name --user-data @$zvsi_name.ign
set +e
sleep 60
zvsi_state=$(ibmcloud is instance $zvsi_name | awk '/Status/{print $2}')
if [ "$zvsi_state" != "running" ]; then
  echo "Error: Instance $zvsi_name is not created properly in the $vpc_name VPC."
  exit 1
else 
  echo "Instance $zvsi_name is created successfully in the $vpc_name VPC."
  rm -rf ./$zvsi_name.ign
fi
nic_name=$(ibmcloud is in-nics $zvsi_name -q | grep -v ID | awk '{print $2}')
echo "Creating a Floating IP for zVSI"
zvsi_fip=$(ibmcloud is ipc $zvsi_name-ip --zone $IC_REGION-1 --resource-group-name $rg_name | awk '/Address/{print $2}')
echo "Assigning the Floating IP for zVSI"
zvsi_fip_status=$(ibmcloud is in-nic-ipc $zvsi_name $nic_name $zvsi_name-ip | awk '/Status/{print $2}')
if [ "$zvsi_fip_status" != "available" ]; then
  echo "Error: Floating IP $zvsi_name-ip is not assigned to the $zvsi_name instance."
  exit 1
else 
  echo "Floating IP $zvsi_name-ip is successfully assigned to the $zvsi_name instance."
fi

# Creating DNS service
echo "Triggering the DNS Service creation on IBM Cloud in the resource group $rg_name"
dns_state=$(ibmcloud dns instance-create $dns_name standard-dns -g $rg_name --output JSON | jq -r '.state')
if [ "$dns_state" == "active" ]; then
  echo "$dns_name DNS instance is created successfully and in active state."
else 
  echo "DNS instance $dns_name is not in the active state."
  exit 1
fi

echo "Creating the DNS zone $dns_zone in the instance $dns_name."
dns_zone_id=$(ibmcloud dns zone-create $dns_zone -i $dns_name --output JSON | jq -r '.id')
if [ -z $dns_zone_id ]; then
  echo "DNS zone $dns_zone is not created properly as it is not possesing any ID."
  exit 1
else 
  echo "DNS zone $dns_zone is created successfully in the instance $dns_name."
fi

echo "Adding VPC network $vpc_name to the DNS zone $dns_zone."
dns_network_state=$(ibmcloud dns permitted-network-add $dns_zone_id --type vpc --vpc-crn $vpc_crn -i $dns_name --output JSON | jq -r '.state')
if [ "$dns_network_state" != "ACTIVE" ]; then
  echo "VPC network $vpc_name which is added to the DNS zone $dns_zone is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $vpc_name is successfully added to the DNS zone $dns_zone."
  echo "DNS zone $dns_zone is in the ACTIVE state."
fi

echo "Adding an A record in the DNS zone $dns_zone to resolve the hosted cluster console to the zVSI compute node IP."
ibmcloud dns resource-record-create $dns_zone_id --type A --name "*.apps.$hc_name.$dns_zone" --ipv4 $zvsi_fip -i $dns_name
if [ $? -eq 0 ]; then
  echo "Successfully added the A record of zVSI compute node IP to resolve the hosted cluster apis."
else 
  echo "A record addition is not successful."
fi

# Checking if the compute node is attached
set -e
echo "Checking if the $zvsi_name compute node is attached to the hosted control plane"
echo "Extracting the hosted cluster kubeconfig"
oc extract -n $hc_ns secret/$hc_name-admin-kubeconfig --kubeconfig=$KUBECONFIG --to=- > $HOME/$hc_name-kubeconfig
set +e
csr_count=1
while true; do
  compute_status=$(oc get no $zvsi_name --kubeconfig="$HOME/$hc_name-kubeconfig" --no-headers=true | awk '{print $2}')
  if [ "$compute_status" != "Ready" ] && [ $csr_count -lt 20 ]; then
    echo "Attempt-$csr_count : Signing the pending CSR to get compute node in ready state/"
    oc get csr --kubeconfig="$HOME/$hc_name-kubeconfig" -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve --kubeconfig="$HOME/$hc_name-kubeconfig"
    csr_count=$((csr_count+1))
    sleep 30
  elif [ "$compute_status" != "Ready" ] && [ $csr_count -eq 20 ]; then
    echo "Error: $zvsi_name compute node is not in ready state, already tried signing the csr 20 times in 30 seconds interval but no luck!!!"
    exit 1
  else
    echo "$zvsi_name compute node is in ready state and attached to the hosted control plane"
    break
  fi
done

# Checking if cluster operators are in true state
echo "Checking the cluster operators status in the hosted control plane"
co_names=$(oc get co --kubeconfig="$HOME/$hc_name-kubeconfig" | awk '$3 == "False" {print $1}')
if [ -n "$co_names" ]; then
  echo "Error: Below cluster operators are not in available state"
  echo $co_names
else 
  echo "All the cluster operators are in True state and are available"
fi

# Checking if the hosted cluster is in complete state
echo "Checking the Hosted Cluster status"
hc_status=$(oc get hc $hc_name -n $hc_ns --kubeconfig=$KUBECONFIG --no-headers=true | awk '{print $3}')
if [ "$hc_status" != "Completed" ]; then
  echo "Error: Hosted Cluster $hc_name is not in completed state"
  exit 1
else 
  echo "Hosted Cluster $hc_name is in completed state and available"
fi