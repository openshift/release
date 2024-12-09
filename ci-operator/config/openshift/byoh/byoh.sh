#!/bin/bash
# $1 : action to perform, it could be 'apply', 'destroy', 'arguments', 'configmap', 'clean'. Default: 'apply'
# $2: name for the byoh instances, it will append a number. Default: "byoh-winc"
# $3: number of byoh workers
# If no argument is passed default number of byoh nodes = 2
# $4: suffix to append to the folder created. This is useful when you have already run the script once
# $5: windows server version to use in BYOH nodes. Accepted: 2019 or 2022
set -eu
set -o pipefail

action="${1:-apply}"
byoh_name="${2:-byoh-winc}"
num_byoh="${3:-2}"
tmp_folder_suffix="${4:-}"
win_version="${5:-2022}"

platform=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}"| tr '[:upper:]' '[:lower:]')

function export_credentials()
{
    case $platform in
        "aws")
            AWS_ACCESS_KEY=$(oc -n kube-system get secret aws-creds -o=jsonpath={.data.aws_access_key_id} | base64 -d)
            AWS_SECRET_ACCESS_KEY=$(oc -n kube-system get secret aws-creds -o=jsonpath={.data.aws_secret_access_key} | base64 -d)
            export AWS_ACCESS_KEY AWS_SECRET_ACCESS_KEY
            ;;
        "gcp")
            GOOGLE_CREDENTIALS=$(oc -n openshift-machine-api get secret gcp-cloud-credentials -o=jsonpath='{.data.service_account\.json}' | base64 -d)
            export GOOGLE_CREDENTIALS
            ;;
        "azure")
            ARM_CLIENT_ID=$(oc -n kube-system get secret azure-credentials -o=jsonpath={.data.azure_client_id} | base64 -d)
            ARM_CLIENT_SECRET=$(oc -n kube-system get secret azure-credentials -o=jsonpath={.data.azure_client_secret} | base64 -d)
            ARM_SUBSCRIPTION_ID=$(oc -n kube-system get secret azure-credentials -o=jsonpath={.data.azure_subscription_id} | base64 -d)
            ARM_TENANT_ID=$(oc -n kube-system get secret azure-credentials -o=jsonpath={.data.azure_tenant_id} | base64 -d)
            ARM_RESOURCE_PREFIX=$(oc -n kube-system get secret azure-credentials -o=jsonpath={.data.azure_resource_prefix} | base64 -d)
            ARM_RESOURCEGROUP=$(oc -n kube-system get secret azure-credentials -o=jsonpath={.data.azure_resourcegroup} | base64 -d)
            export ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_RESOURCE_PREFIX ARM_RESOURCEGROUP
            ;;
        "vsphere")
            VSPHERE_USER=$(oc -n kube-system get secret vsphere-creds -o=jsonpath='{.data.vcenter\.devqe\.ibmc\.devcluster\.openshift\.com\.username}' | base64 -d)
            VSPHERE_PASSWORD=$(oc -n kube-system get secret vsphere-creds -o=jsonpath='{.data.vcenter\.devqe\.ibmc\.devcluster\.openshift\.com\.password}' | base64 -d)
            VSPHERE_SERVER="vcenter.devqe.ibmc.devcluster.openshift.com"
            export VSPHERE_USER VSPHERE_PASSWORD VSPHERE_SERVER
            ;;
		"nutanix")
			NUTANIX_CREDS=$(oc -n openshift-machine-api get secret nutanix-credentials -o=jsonpath='{.data.credentials}' | base64 -d)
			NUTANIX_USERNAME=$(echo $NUTANIX_CREDS | jq -r '.[0].data.prismCentral.username')
			NUTANIX_PASSWORD=$(echo $NUTANIX_CREDS | jq -r '.[0].data.prismCentral.password')
			export NUTANIX_USERNAME NUTANIX_PASSWORD
			;;
        "none")
            if ([ ! -f $HOME/.aws/config ] || [ ! -f $HOME/.aws/credentials ])
            then
                echo "ERROR: Can't load AWS user credentials" >&2
                echo "ERROR: Configure your AWS account following: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html" >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: Platform ${platform} not supported. Aborting execution." >&2
            exit 1
            ;;
    esac
}

# Call the function to export credentials
export_credentials

# Rest of your script...
echo "Credentials exported successfully. Proceeding with the script..."

function get_terraform_arguments()
{
	terraform_args=""
	case $platform in

		"aws")
            winMachineHostname=$(oc get nodes -l "node-role.kubernetes.io/worker,windowsmachineconfig.openshift.io/byoh!=true" -o=jsonpath="{.items[0].status.addresses[?(@.type=='Hostname')].address}")
			windowsAmi=$(oc get machineset.machine.openshift.io -n openshift-machine-api -o=jsonpath="{.items[?(@.spec.template.metadata.labels.machine\.openshift\.io\/os-id=='Windows')].spec.template.spec.providerSpec.value.ami.id}")
		    clusterName=$(oc get machineset.machine.openshift.io -n openshift-machine-api -o=jsonpath="{.items[?(@.spec.template.metadata.labels.machine\.openshift\.io\/os-id=='Windows')].metadata.labels.machine\.openshift\.io\/cluster-api-cluster}")
		    region=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.aws.region}")

			terraform_args="--var winc_number_workers=${num_byoh} --var winc_machine_hostname=${winMachineHostname} --var winc_instance_name=${byoh_name} --var winc_worker_ami=${windowsAmi} --var winc_cluster_name=${clusterName} --var winc_region=${region}"
			;;
		"gcp")
			# If the hostname is short then the whole FQDN will appear, we just need the hostname part, so splitting
			# by using dot and taking the first element.
            winMachineHostname=$(oc get nodes -l "node-role.kubernetes.io/worker,windowsmachineconfig.openshift.io/byoh!=true" -o=jsonpath="{.items[0].status.addresses[?(@.type=='Hostname')].address}" | cut -d "." -f1)
			zone=$(oc get machine.machine.openshift.io -n openshift-machine-api -o=jsonpath="{.items[0].metadata.labels.machine\.openshift\.io\/zone}")
		    region=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.gcp.region}")

			terraform_args="--var winc_number_workers=${num_byoh} --var winc_machine_hostname=${winMachineHostname} --var winc_instance_name=${byoh_name} --var winc_zone=${zone} --var winc_region=${region}"
			;;
		"azure")
			# In azure, computere name can't take more than 15 characters. As we are adding
			# -0, -1, -2 depending on the number of Terraform nodes, we need to limit the
			# size to 13 characters.
            if (( ${#byoh_name} > 13 )); then
                byoh_name="${byoh_name:0:13}"
            fi
            winMachineHostname=$(oc get nodes -l "node-role.kubernetes.io/worker,windowsmachineconfig.openshift.io/byoh!=true" -o=jsonpath="{.items[0].status.addresses[?(@.type=='Hostname')].address}")
			windowsSku=$(oc get machineset.machine.openshift.io -n openshift-machine-api -o=jsonpath="{.items[?(@.spec.template.metadata.labels.machine\.openshift\.io\/os-id=='Windows')].spec.template.spec.providerSpec.value.image.sku}")
            #windowsSku="2019-Datacenter"
            #windowsSku="2022-datacenter"
			terraform_args="--var winc_number_workers=${num_byoh} --var winc_machine_hostname=${winMachineHostname} --var winc_instance_name=${byoh_name} --var winc_resource_group=${ARM_RESOURCEGROUP} --var winc_resource_prefix=${ARM_RESOURCE_PREFIX} --var winc_worker_sku=${windowsSku}"
			;;
		"vsphere")
			windowsTemplate=$(oc get machineset.machine.openshift.io -n openshift-machine-api -o=jsonpath="{.items[?(@.spec.template.metadata.labels.machine\.openshift\.io\/os-id=='Windows')].spec.template.spec.providerSpec.value.template}")

			terraform_args="--var winc_number_workers=${num_byoh} --var winc_instance_name=${byoh_name} --var winc_vsphere_template=${windowsTemplate}"
			;;
		"nutanix")
			cluster_name="Development-LTS"
			# Get subnet UUID from the machineset configuration
			subnet_uuid=$(oc get -n openshift-machine-api machineset winworker -o jsonpath='{.spec.template.spec.providerSpec.value.subnets[0].uuid}')
			
			terraform_args="--var winc_number_workers=${num_byoh} \
						--var winc_instance_name=${byoh_name} \
						--var winc_cluster_name=${cluster_name} \
						--var nutanix_username=${NUTANIX_USERNAME} \
						--var nutanix_password=${NUTANIX_PASSWORD} \
						--var subnet_uuid=${subnet_uuid}"
			;;
		"none")
			linuxNode=$(oc get nodes -l "node-role.kubernetes.io/worker,windowsmachineconfig.openshift.io/byoh!=true" -o=jsonpath="{.items[0].status.addresses[?(@.type=='Hostname')].address}")
			ipLinuxNode=$(oc get node ${linuxNode} -o=jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}")
			# when calling nslookup, the output returns a dot at the very end. | sed 's/\.$//' takes care of removing it.
			linuxNodeHostname=$(oc debug node/${linuxNode} -- nslookup ${ipLinuxNode} 2> /dev/null | grep -oE 'name = ([^.]*.*)' | sed -E 's/name = (.*)\.$/\1/')
			region=$(echo ${linuxNodeHostname} | cut -d "." -f2)

			terraform_args="--var winc_number_workers=${num_byoh} --var winc_machine_hostname=${linuxNodeHostname} --var winc_instance_name=${byoh_name} --var winc_version=${win_version} --var winc_region=${region}"
			;;
		*)
			echo "ERROR: Platform ${platform} not supported. Aborting execution."
            exit 1

			;;
	esac

	echo "${terraform_args}"

}

function get_user_name() {
	case $platform in
		"aws"|"gcp"|"vsphere"|"none"|"nutanix")
			echo "Administrator"
			;;
		"azure")
			echo "capi"
			;;
		*)
			echo "ERROR: Platform ${platform} not supported. Aborting execution."
            exit 1
			;;
	esac
}

tmp_dir="/tmp/terraform_byoh/"
templates_dir="${tmp_dir}${platform}${tmp_folder_suffix}"
case $action in 

	"apply")
		if [ -d $templates_dir ]
		then
			echo "The directory $templates_dir already exists, do you want to get rid of its content?(yes or no)"
			read -p "Answer: " answer
			case $answer in
				"yes")
					rm -r $templates_dir
					cp -R ./$platform $templates_dir
					;;
				"no")
					echo "Terraform apply will be re-executed using templates located in ${templates_dir}"
					;;
				"*")
					echo "ERROR: Unsupported answer ${answer}, write 'yes' or 'no'. Aborting execution."
            		exit 1
					;;
				
			esac
		else
			mkdir -p $tmp_dir
			cp -R ./$platform $templates_dir
		fi
		export_credentials
		cd $templates_dir
		terraform init
		terraform apply --auto-approve $(get_terraform_arguments)

	    # Create configmap and apply it (follows to apply)
		if [ ! -d $templates_dir ]
		then
			echo "ERROR: Directory ${templates_dir} not created. Did you run ./byoh.sh apply first?"
            exit 1
		fi

		wmco_namespace=$(oc get deployment --all-namespaces -o=jsonpath="{.items[?(@.metadata.name=='windows-machine-config-operator')].metadata.namespace}")
		cd $templates_dir
		cat << EOF  > byoh_cm.yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: windows-instances
  namespace: ${wmco_namespace}
data:
$(
	for ip in $(terraform output --json instance_ip | jq -c '.[]')
	do
		echo -e "  ${ip}: |-\n    username=$(get_user_name)"
	done
)
EOF
	oc create -f "${templates_dir/byoh_cm.yaml}"

		;;
	"configmap")
	# Create configmap and apply it (in case you need to relaunch it)
		if [ ! -d $templates_dir ]
		then
			echo "ERROR: Directory ${templates_dir} not created. Did you run ./byoh.sh apply first?"
            exit 1
		fi

		wmco_namespace=$(oc get deployment --all-namespaces -o=jsonpath="{.items[?(@.metadata.name=='windows-machine-config-operator')].metadata.namespace}")
		cd $templates_dir
		cat << EOF  > byoh_cm.yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: windows-instances
  namespace: ${wmco_namespace}
data:
$(
	for ip in $(terraform output --json instance_ip | jq -c '.[]')
	do
		echo -e "  ${ip}: |-\n    username=$(get_user_name)"
	done
)
EOF
	oc create -f "${templates_dir/byoh_cm.yaml}"
		;;
	"destroy")
		if [ ! -d $templates_dir ]
		then
			echo "ERROR: Directory ${templates_dir} not created. Did you run ./byoh.sh apply first?"
            exit 1
		fi

		# Delete the configmap if exists
		if [ -e "${templates_dir/byoh_cm.yaml}" ]
		then
		    wmco_namespace=$(oc get deployment --all-namespaces -o=jsonpath="{.items[?(@.metadata.name=='windows-machine-config-operator')].metadata.namespace}")
			if oc get cm windows-instances -n ${wmco_namespace}
			then
				oc delete -f "${templates_dir/byoh_cm.yaml}"
			fi
		fi
		export_credentials
		cd $templates_dir
		terraform destroy --auto-approve $(get_terraform_arguments)
		
		rm -r $templates_dir
		;;
	"clean")
		rm -r $templates_dir
		;;
	"arguments")
		echo $(get_terraform_arguments)
		;;
	"help")
		echo "
		\$1: action to perform, it could be 'apply', 'destroy', 'arguments', 'configmap', 'clean'. Default: 'apply'
		\$2: name for the byoh instances, it will append a number. Default: "byoh-winc"
		\$3: number of byoh workers. If no argument is passed default number of byoh nodes = 2
		\$4: suffix to append to the folder created. This is useful when you have already run the script once
		\$5: windows server version to use in BYOH nodes. Accepted: 2019 or 2022

		Example for BYOH: ./byoh.sh apply byoh 1 '' 2019
		Example for others: ./byoh.sh apply winc-byoh 4 ''
		Example if multiple runs of same cloud provider: 
		   * Azure 2019: ./byoh.sh apply byoh-winc 2 '-az2019'
		   * Azure 2022: ./byoh.sh apply byoh-winc 2 '-az2022'
		"
		;;
	*)
		echo "ERROR: Option ${action} not supported. Use: apply, destroy, arguments, clean, configmap"
    	exit 1
		;;
esac


