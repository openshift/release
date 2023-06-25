#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR:=""}
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json

CLUSTER_NAME=${CLUSTER_NAME:=""}
platform_type=$(oc get infrastructure cluster -o=jsonpath={.status.platformStatus.type})
platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')
export CLUSTER_NAME=$(oc get machineset -n openshift-machine-api -o=go-template='{{(index (index .items 0).metadata.labels "machine.openshift.io/cluster-api-cluster" )}}')
PROVISION_OR_TEARDOWN=${PROVISION_OR_TEARDOWN:="PROVISION"}
case ${platform_type} in
     aws)
        export NETWORK_NAME=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,PrivateIpAddress,PublicIpAddress, PrivateDnsName, VpcId]' --output text | column -t  | grep $CLUSTER_NAME  | awk '{print $7}' | grep -v '^$' | sort -u)
        if [[ $PROVISION_OR_TEARDOWN == "PROVISION" ]]; then
	   echo "Set seurity group rules for $NETWORK_NAME on $platform_type"

	   echo 
           for security_group in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$NETWORK_NAME" --output json | jq -r ".SecurityGroups[].GroupId");
           do
		  echo "Adding authorize-security-group-ingress rules for $security_group"
		  aws ec2 authorize-security-group-ingress --group-id $security_group --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges="[{CidrIp=0.0.0.0/0,Description='PerfScale Testing'}]"
		  aws ec2 authorize-security-group-ingress --group-id $security_group --ip-permissions IpProtocol=tcp,FromPort=2022,ToPort=2022,IpRanges="[{CidrIp=0.0.0.0/0,Description='PerfScale Testing'}]"
		  aws ec2 authorize-security-group-ingress --group-id $security_group --ip-permissions IpProtocol=tcp,FromPort=20000,ToPort=20109,IpRanges="[{CidrIp=0.0.0.0/0,Description='PerfScale Testing'}]"
		  aws ec2 authorize-security-group-ingress --group-id $security_group --ip-permissions IpProtocol=udp,FromPort=20000,ToPort=20109,IpRanges="[{CidrIp=0.0.0.0/0,Description='PerfScale Testing'}]"
		  aws ec2 authorize-security-group-ingress --group-id $security_group --ip-permissions IpProtocol=tcp,FromPort=32768,ToPort=60999,IpRanges="[{CidrIp=0.0.0.0/0,Description='PerfScale Testing'}]"
		  aws ec2 authorize-security-group-ingress --group-id $security_group --ip-permissions IpProtocol=udp,FromPort=32768,ToPort=60999,IpRanges="[{CidrIp=0.0.0.0/0,Description='PerfScale Testing'}]"

                  #aws ec2 authorize-security-group-ingress --group-id $security_group --protocol tcp --port 22 --cidr 0.0.0.0/0 
                  #aws ec2 authorize-security-group-ingress --group-id $security_group --protocol tcp --port 2022 --cidr 0.0.0.0/0
                  #aws ec2 authorize-security-group-ingress --group-id $security_group --protocol tcp --port 20000-20109 --cidr 0.0.0.0/0
                  #aws ec2 authorize-security-group-ingress --group-id $security_group --protocol udp --port 20000-20109 --cidr 0.0.0.0/0
                  #aws ec2 authorize-security-group-ingress --group-id $security_group --protocol tcp --port 32768-60999 --cidr 0.0.0.0/0
                  #aws ec2 authorize-security-group-ingress --group-id $security_group --protocol udp --port 32768-60999 --cidr 0.0.0.0/0
		  aws ec2 describe-security-groups --group-ids $security_group  --query "SecurityGroups[*].IpPermissions[*].{IpProtocol:IpProtocol,IpRanges:IpRanges[0].CidrIp,FromPort:FromPort,ToPort:ToPort}" --output table
		  #aws ec2 describe-security-groups --group-ids $security_group  --query "SecurityGroups[*].IpPermissions[*].{From_IpRanges:IpRanges[0].CidrIp,IpProtocol:IpProtoco,FromPort:FromPort,ToPort:ToPort}" --output table
           done
        fi
        if [[ $PROVISION_OR_TEARDOWN == "TEARDOWN" ]]; then

          echo "Remove Firewall Rules"
          for security_group in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$NETWORK_NAME" --output json | jq -r ".SecurityGroups[].GroupId"); do
                  aws ec2 revoke-security-group-ingress --group-id $security_group --protocol tcp --port 22 --cidr 0.0.0.0/0
                  aws ec2 revoke-security-group-ingress --group-id $security_group --protocol tcp --port 2022 --cidr 0.0.0.0/0
                  aws ec2 revoke-security-group-ingress --group-id $security_group --protocol tcp --port 20000-20109 --cidr 0.0.0.0/0
                  aws ec2 revoke-security-group-ingress --group-id $security_group --protocol udp --port 20000-20109 --cidr 0.0.0.0/0
                  aws ec2 revoke-security-group-ingress --group-id $security_group --protocol tcp --port 32768-60999 --cidr 0.0.0.0/0
                  aws ec2 revoke-security-group-ingress --group-id $security_group --protocol udp --port 32768-60999 --cidr 0.0.0.0/0
          done
       fi
          ;;
     azure)
       if [[ $PROVISION_OR_TEARDOWN == "PROVISION" ]]; then
         # create azure profile
         az login --service-principal -u `cat $AZURE_AUTH_LOCATION | jq -r '.clientId'` -p "`cat $AZURE_AUTH_LOCATION | jq -r '.clientSecret'`" --tenant `cat $AZURE_AUTH_LOCATION | jq -r '.tenantId'`
         az account set --subscription `cat $AZURE_AUTH_LOCATION | jq -r '.subscriptionId'`

         export NETWORK_NAME=$(az network nsg list -g  $CLUSTER_NAME-rg --query "[].name" -o tsv | grep "nsg")

         echo "Add Firewall Rules for $platform_type"
         az network nsg rule create -g $CLUSTER_NAME-rg --name scale-ci-icmp --nsg-name  $NETWORK_NAME --priority 100 --access Allow --description "scale-ci allow Icmp" --protocol Icmp --destination-port-ranges "*"
         az network nsg rule create -g $CLUSTER_NAME-rg --name scale-ci-ssh --nsg-name  $NETWORK_NAME --priority 103 --access Allow --description "scale-ci allow ssh" --protocol Tcp --destination-port-ranges "22"
         az network nsg rule create -g $CLUSTER_NAME-rg --name scale-ci-pbench-agent --nsg-name $NETWORK_NAME --priority 102 --access Allow --description "scale-ci allow pbench-agent" --protocol Tcp --destination-port-ranges "2022"
         az network nsg rule create -g $CLUSTER_NAME-rg --name scale-ci-net --nsg-name $NETWORK_NAME --priority 104 --access Allow --description "scale-ci allow tcp,udp network tests" --protocol "*" --destination-port-ranges "20000-20109"
         # Typically `net.ipv4.ip_local_port_range` is set to `32768 60999` in which uperf will pick a few random ports to send flags over.
         # Currently there is no method outside of sysctls to control those ports
         # See pbench issue #1238 - https://github.com/distributed-system-analysis/pbench/issues/1238
         az network nsg rule create -g $CLUSTER_NAME-rg --name scale-ci-hostnet --nsg-name $NETWORK_NAME --priority 106 --access Allow --description "scale-ci allow tcp,udp hostnetwork tests" --protocol "*" --destination-port-ranges "32768-60999"
         az network nsg rule list -g $CLUSTER_NAME-rg  --nsg-name $NETWORK_NAME  | grep scale
       fi

       if [[ $PROVISION_OR_TEARDOWN == "TEARDOWN" ]]; then
                  echo "Remove Firewall Rules"
                  az network nsg rule delete -g $CLUSTER_NAME-rg --nsg-name $NETWORK_NAME --name scale-ci-icmp
                  az network nsg rule delete -g $CLUSTER_NAME-rg --nsg-name $NETWORK_NAME --name scale-ci-ssh
                  az network nsg rule delete -g $CLUSTER_NAME-rg --nsg-name $NETWORK_NAME --name scale-ci-pbench-agent
                  az network nsg rule delete -g $CLUSTER_NAME-rg --nsg-name $NETWORK_NAME --name scale-ci-net
                  az network nsg rule delete -g $CLUSTER_NAME-rg --nsg-name $NETWORK_NAME --name scale-ci-hostnet
       fi
          ;;
     gcp)

         # login to service account
         gcloud auth activate-service-account `cat $GCP_SHARED_CREDENTIALS_FILE | jq -r '.client_email'`  --key-file=$GCP_SHARED_CREDENTIALS_FILE --project=`cat $GCP_SHARED_CREDENTIALS_FILE | jq -r '.project_id'`
         gcloud auth list
         gcloud config set account `cat $GCP_SHARED_CREDENTIALS_FILE | jq -r '.client_email'`

         export NETWORK_NAME=$(gcloud compute networks list  | grep $CLUSTER_NAME | awk '{print $1}')

         if [[ $NETWORK_NAME == "" ]]; then
             sub_cluster_name=$(echo ${CLUSTER_NAME%-*})
             export NETWORK_NAME=$(gcloud compute networks list  | grep $sub_cluster_name | awk '{print $1}')

         fi
         echo $NETWORK_NAME
         if [[ $PROVISION_OR_TEARDOWN == "PROVISION" ]]; then
            echo "Add Firewall Rules"
            gcloud compute firewall-rules create $CLUSTER_NAME-scale-ci-icmp --network $NETWORK_NAME --priority 101 --description "scale-ci allow icmp" --allow icmp
            gcloud compute firewall-rules create $CLUSTER_NAME-scale-ci-ssh --network $NETWORK_NAME --direction INGRESS --priority 102  --description "scale-ci allow ssh" --allow tcp:22
            gcloud compute firewall-rules create $CLUSTER_NAME-scale-ci-pbench --network $NETWORK_NAME --direction INGRESS --priority 103 --description "scale-ci allow pbench-agents" --allow tcp:2022
            gcloud compute firewall-rules create $CLUSTER_NAME-scale-ci-net --network $NETWORK_NAME --direction INGRESS --priority 104 --description "scale-ci allow tcp,udp network tests" --rules tcp,udp:20000-20109 --action allow
            gcloud compute firewall-rules create $CLUSTER_NAME-scale-ci-hostnet --network $NETWORK_NAME --priority 105 --description "scale-ci allow tcp,udp hostnetwork tests" --rules tcp,udp:32768-60999 --action allow
            gcloud compute firewall-rules list | grep $CLUSTER_NAME
         fi
         if [[ $PROVISION_OR_TEARDOWN == "TEARDOWN" ]]; then
                  echo "Remove Firewall Rules"
                  gcloud compute firewall-rules delete $CLUSTER_NAME-scale-ci-icmp --quiet
                  gcloud compute firewall-rules delete $CLUSTER_NAME-scale-ci-ssh --quiet
                  gcloud compute firewall-rules delete $CLUSTER_NAME-scale-ci-pbench --quiet
                  gcloud compute firewall-rules delete $CLUSTER_NAME-scale-ci-net --quiet
                  gcloud compute firewall-rules delete $CLUSTER_NAME-scale-ci-hostnet --quiet
                  gcloud compute firewall-rules list | grep $CLUSTER_NAME
         fi
	 ;;
esac
