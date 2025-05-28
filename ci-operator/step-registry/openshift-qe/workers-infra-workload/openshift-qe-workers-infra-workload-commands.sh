#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

function print_node_machine_info() {

    label=$1
    echo "##########################################Machineset and Node Status##############################"
    oc get machinesets.m -A
    echo "--------------------------------------------------------------------------------------------------"
    echo
    oc get machines.m -A
    echo "--------------------------------------------------------------------------------------------------"
    echo
    oc get nodes
    echo "--------------------------------------------------------------------------------------------------"
    echo
    echo "--------------------------------Abnormal Machineset and Node Info---------------------------------"
    for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/$label= | egrep -e "NotReady|SchedulingDisabled" | awk '{print $1}'); do
        oc describe node $node
    done

    for machine in $(oc get machines.m -n openshift-machine-api --no-headers -l machine.openshift.io/cluster-api-machine-type=$label| grep -v "Running" | awk '{print $1}'); do
        oc describe machine $machine -n openshift-machine-api
    done
}

function get_ref_machineset_info(){
  machineset_name=$1
  platform_type=$(oc get infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
  platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')

  if [[ -z ${machineset_name} ]];then
       echo "No machineset was specified, please check"
       exit 1
  else

       echo "Choose $machineset_name as an reference machineset"
  fi
  instance_type=""
  volumeSize=""
  volumeType=""
  volumeIPOS=""
  cpusPerSocket=""
  memorySize=""
  case ${platform_type} in
       aws)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.instanceType}')
          volumeType=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.blockDevices[*].ebs.volumeType}')
          volumeSize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.blockDevices[*].ebs.volumeSize}')
          volumeIPOS=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.blockDevices[*].ebs.iops}')
          ;;
       azure)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.vmSize}')
          volumeSize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.osDisk.diskSizeGB}')
          volumeType=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.osDisk.managedDisk.storageAccountType}')
          ;;
        gcp)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.machineType}')
          volumeSize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.disks[*].sizeGb}')
          volumeType=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.disks[*].type}')
          ;;
        ibmcloud)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.profile}')
          ;;
        alibabacloud)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.instanceType}')
          volumeType=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.systemDisk.category}')
          volumeSize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.systemDisk.size}')
          ;;
        openstack)
	  instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.flavor}')
          ;;
        nutanix)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.vcpuSockets}')
          cpusPerSocket=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.vcpusPerSocket}')
          memorySize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.memorySize}')
          volumeSize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.systemDiskSize}')
          ;;
        vsphere)
          instance_type=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.numCPUs}')
          cpusPerSocket=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.numCoresPerSocket}')
          memorySize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.memoryMiB}')
          volumeSize=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.diskGiB}')
          volumeType=$(oc -n openshift-machine-api get machinesets.m $machineset_name -ojsonpath='{.spec.template.spec.providerSpec.value.kind}')
          ;;
        *)
          echo "Non supported platform detected ..."o
          exit 1
  esac

  if [[ -n $instance_type ]];then
      export instance_type
  fi

  if [[ -n $cpusPerSocket ]];then
      export cpusPerSocket
  fi

  if [[ -n $memorySize ]];then
      export memorySize
  fi

  if [[ -n $volumeSize ]];then
      export volumeSize
  fi
  if [[ -n $volumeType ]];then
      export volumeType
  fi
  if [[ -n $volumeIPOS ]];then 
     export volumeIPOS
  fi
  echo -e "###########################################################################################\n"
}

function create_machineset() {
    # Get machineset name to generate a generic template

    #REF_MACHINESET_NAME -- Use the specified worker machineset as reference machineset template

    #NODE_REPLICAS -- specify the machineset replicas number

    #MACHINESET_TYPE -- infra or workload machineset

    #NODE_INSTANCE_TYPE -- m5.12xlarge or Standard_D48s_v3 ...

    #VOLUME_TYPE -- gp3. different cloud provider with different name 

    #VOLUME_SIZE -- 100 volume size

    #VOLUME_IOPS -- 3000 volume IPOS
    OPTIND=1
    while getopts m:r:t:x:u:v:w: FLAG
    do
       case "${FLAG}" in
        m) REF_MACHINESET_NAME=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		REF_MACHINESET_NAME=""
           fi
		;;
        r) NODE_REPLICAS=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		NODE_REPLICAS=""
           fi
		;;
        t) MACHINESET_TYPE=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		MACHINESET_TYPE=""
           fi
		;;
        x) NODE_INSTANCE_TYPE=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		NODE_INSTANCE_TYPE=""
           fi
		;;
        u) VOLUME_TYPE=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		VOLUME_TYPE=""
           fi
		;;
        v) VOLUME_SIZE=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		VOLUME_SIZE=""
           fi
		;;
        w) VOLUME_IOPS=${OPTARG}
	   if [[ ${OPTARG} == "none" ]];then
		VOLUME_IOPS=""
           fi
		;;
	*) echo "Invalid parameter, unsupported option ${FLAG}"
           exit 1;;
       esac
    done
    #Optional

    #Get current platform that OCP deploy, aws,gcp,ibmcloud,alicloud etc.
    platform_type=$(oc get infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
    platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')

    #Set default value for key VARIABLE
    #Use the first machineset name by default if no REF_MACHINESET_NAME specified
    ref_machineset_name=$(oc -n openshift-machine-api get -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' machinesets.m | grep worker | grep -v rhel | head -n1)
    REF_MACHINESET_NAME=${REF_MACHINESET_NAME:-$ref_machineset_name}

    get_ref_machineset_info $REF_MACHINESET_NAME

    #Set default value for variable
    NODE_REPLICAS=${NODE_REPLICAS:-1}
    NODE_INSTANCE_TYPE=${NODE_INSTANCE_TYPE:-$instance_type}
    MACHINESET_TYPE=${MACHINESET_TYPE:-"infra"}
    VOLUME_TYPE=${VOLUME_TYPE:-$volumeType}
    VOLUME_SIZE=${VOLUME_SIZE:-$volumeSize}
    VOLUME_IOPS=${VOLUME_IOPS:-$volumeIPOS}
    INSTANCE_VCPU=""
    NODE_CPU_COUNT=""
    NODE_CPU_CORE_PER_SOCKET_COUNT=""
    INSTANCE_MEMORYSIZE=""
    NODE_MEMORY_SIZE=""

    # Replace machine name worker to infra
    machineset_name="${REF_MACHINESET_NAME/worker/${MACHINESET_TYPE}}"

    #export ref_machineset_name machineset_name

    # Get a templated json from worker machineset, change machine type and machine name
    # and pass it to oc to create a new machine set

    case ${platform_type} in
        aws)
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_INSTANCE_TYPE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg volumeType "${VOLUME_TYPE}" \
                 --arg volumeSize "${VOLUME_SIZE}" \
                 --arg volumeIPOS "${VOLUME_IOPS}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.instanceType = $node_instance_type |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.blockDevices[0].ebs.volumeType = $volumeType |
		  .spec.template.spec.providerSpec.value.blockDevices[0].ebs.volumeSize = ($volumeSize|tonumber) |
		  .spec.template.spec.providerSpec.value.blockDevices[0].ebs.iops = ($volumeIPOS|tonumber) |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
            ;;
        azure)
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_INSTANCE_TYPE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg volumeType "${VOLUME_TYPE}" \
                 --arg volumeSize "${VOLUME_SIZE}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.vmSize = $node_instance_type |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.osDisk.managedDisk.storageAccountType = $volumeType |
		  .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = ($volumeSize|tonumber) |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
            ;;
        gcp)
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_INSTANCE_TYPE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg volumeType "${VOLUME_TYPE}" \
                 --arg volumeSize "${VOLUME_SIZE}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.machineType = $node_instance_type |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.disks[0].type = $volumeType |
		  .spec.template.spec.providerSpec.value.disks[0].sizeGb = ($volumeSize|tonumber) |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
            ;;
        ibmcloud)
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_INSTANCE_TYPE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.profile = $node_instance_type |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
            ;;
        alibabacloud)
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_INSTANCE_TYPE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg volumeType "${VOLUME_TYPE}" \
                 --arg volumeSize "${VOLUME_SIZE}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.instanceType = $node_instance_type |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
                  .spec.template.spec.providerSpec.value.systemDisk.category = $volumeType |
		  .spec.template.spec.providerSpec.value.systemDisk.size = ($volumeSize|tonumber) |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
               ;;
        vsphere)
		if [[ ${MACHINESET_TYPE} == "infra" ]];then
                   NODE_CPU_COUNT=${OPENSHIFT_INFRA_NODE_CPU_COUNT:-$instance_type}
                   NODE_CPU_CORE_PER_SOCKET_COUNT=${OPENSHIFT_INFRA_NODE_CPU_CORE_PER_SOCKET_COUNT:-$cpusPerSocket}
                   NODE_MEMORY_SIZE=${OPENSHIFT_INFRA_NODE_MEMORY_SIZE:-$memorySize}
		elif [[ ${MACHINESET_TYPE} == "workload"  ]];then
                   NODE_CPU_COUNT=${OPENSHIFT_WORKLOAD_NODE_CPU_COUNT:-$instance_type}
                   NODE_CPU_CORE_PER_SOCKET_COUNT=${OPENSHIFT_WORKLOAD_NODE_CPU_CORE_PER_SOCKET_COUNT:-$cpusPerSocket}
                   NODE_MEMORY_SIZE=${OPENSHIFT_WORKLOAD_NODE_MEMORY_SIZE:-$memorySize}
		fi
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_CPU_COUNT}" \
                 --arg numCoresPerSocket "${NODE_CPU_CORE_PER_SOCKET_COUNT}" \
                 --arg ramSize "${NODE_MEMORY_SIZE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg volumeSize "${VOLUME_SIZE}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
		  .spec.template.spec.providerSpec.value.numCPUs = ($node_instance_type|tonumber) |
		  .spec.template.spec.providerSpec.value.numCoresPerSocket = ($numCoresPerSocket|tonumber) |
		  .spec.template.spec.providerSpec.value.memoryMiB = ($ramSize|tonumber) |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
		  .spec.template.spec.providerSpec.value.diskGiB = ($volumeSize|tonumber) |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
		;;
        openstack)
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${NODE_INSTANCE_TYPE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
		  .spec.template.spec.providerSpec.value.flavor = $node_instance_type |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
            ;;
        nutanix)
	    if [[ ${MACHINESET_TYPE} == "infra" ]];then
              INSTANCE_VCPU=${OPENSHIFT_INFRA_NODE_INSTANCE_VCPU:-$instance_type}
              INSTANCE_MEMORYSIZE=${OPENSHIFT_INFRA_NODE_INSTANCE_MEMORYSIZE:-$memorySize}
            elif [[ ${MACHINESET_TYPE} == "workload" ]];then
              INSTANCE_VCPU=${OPENSHIFT_WORKLOAD_NODE_INSTANCE_VCPU:-$instance_type}
              INSTANCE_MEMORYSIZE=${OPENSHIFT_WORKLOAD_NODE_INSTANCE_MEMORYSIZE:-$memorySize}  
            else
	      echo "Please specify correct VARIABLE for nutanix:\n OPENSHIFT_INFRA_NODE_INSTANCE_VCPU\nOPENSHIFT_INFRA_NODE_INSTANCE_MEMORYSIZE\nOPENSHIFT_WORKLOAD_NODE_INSTANCE_VCPU\nOPENSHIFT_WORKLOAD_NODE_INSTANCE_MEMORYSIZE"
	    exit 1
            fi
            oc get machinesets.m ${REF_MACHINESET_NAME} -n openshift-machine-api -o json |
              jq --arg node_instance_type "${INSTANCE_VCPU}" \
                 --arg cpusPerSocket "${cpusPerSocket}" \
                 --arg memorySize "${INSTANCE_MEMORYSIZE}" \
                 --arg machineset_name "${machineset_name}" \
                 --arg machinesetType "${MACHINESET_TYPE}" \
                 '.metadata.name = $machineset_name |
                  .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
		  .spec.template.spec.providerSpec.value.vcpuSockets = ($node_instance_type|tonumber) |
		  .spec.template.spec.providerSpec.value.vcpusPerSocket = ($cpusPerSocket|tonumber) |
		  .spec.template.spec.providerSpec.value.memorySize = $memorySize |
                  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $machineset_name |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
	          .metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
	          .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = $machinesetType |
		  .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = $machinesetType |
                  del(.status) |
                  del(.metadata.selfLink) |
                  del(.metadata.uid)
                  '>/tmp/machineset.json
		;;
         *)
		 echo "Un-supported platform $platform_type deletected"
		 exit 1
		 ;;
    esac

    echo
    echo "Information that will be used for deploy $MACHINESET_TYPE nodes" 
    echo "###########################################################################################"
    echo -e "Reference Machineset Name: $REF_MACHINESET_NAME \nNODE_REPLICAS: $NODE_REPLICAS\nMACHINESET_TYPE: $MACHINESET_TYPE\nNODE_INSTANCE_TYPE: $NODE_INSTANCE_TYPE\nINSTANCE_VCPU: $INSTANCE_VCPU\nNODE_CPU_COUNT: $NODE_CPU_COUNT\nNODE_CPU_CORE_PER_SOCKET_COUNT: $NODE_CPU_CORE_PER_SOCKET_COUNT\nINSTANCE_MEMORYSIZE: $INSTANCE_MEMORYSIZE\ncpusPerSocket: $cpusPerSocket\nnNODE_MEMORY_SIZE: $NODE_MEMORY_SIZE\nVOLUME_TYPE: $VOLUME_TYPE\nVOLUME_SIZE: $VOLUME_SIZE\nVOLUME_IOPS: $VOLUME_IOPS"
    echo "It's normal if some ENV is empty, vsphere and nutanix use INSTANCE_VCPU/NODE_CPU_COUNT instead of NODE_INSTANCE_TYPE"
    echo "###########################################################################################"
    if [[ $MACHINESET_TYPE == "infra" ]];then
        cat /tmp/machineset.json | jq '.spec.template.spec.metadata.labels."node-role.kubernetes.io/infra" = ""' | oc create -f -
    elif [[ $MACHINESET_TYPE == "workload" ]];then
        cat /tmp/machineset.json | jq '.spec.template.spec.metadata.labels."node-role.kubernetes.io/workload" = ""' | oc create -f -
    else
        echo "No support label type, please check ..."
        exit 1
    fi
    # Scale machineset to expected number of replicas
    oc -n openshift-machine-api scale machinesets.m/"${machineset_name}" --replicas="${NODE_REPLICAS}"

    echo "Waiting for ${MACHINESET_TYPE} nodes to come up"
    retries=0
    attempts=180
    while [[ $(oc -n openshift-machine-api get machinesets.m/${machineset_name} -o 'jsonpath={.status.readyReplicas}') != "${NODE_REPLICAS}" ]];
    do 
        ((retries += 1))
        echo -n "." && sleep 10;
        if [[ ${retries} -gt ${attempts} ]]; then
            echo -e "\n\nError: infra nodes didn't become READY in time, failing, please check"
            print_node_machine_info ${MACHINESET_TYPE}
            exit 1
        fi 
        
    done

    # Collect infra node names
    mapfile -t INFRA_NODE_NAMES < <(echo "$(oc get nodes -l node-role.kubernetes.io/${MACHINESET_TYPE} -o name)" | sed 's;node\/;;g')
    echo -e "\n___________________________________________________________________________________________"
    echo
    echo "${MACHINESET_TYPE} nodes ${INFRA_NODE_NAMES[*]} are up"
    # this infra node will not be managed by any default MCP after removing the default worker role,
    # it will leads to some configs cannot be applied to this infra node, such as, ICSP, details: https://issues.redhat.com/browse/OCPBUGS-10596
    oc label nodes --overwrite -l "node-role.kubernetes.io/${MACHINESET_TYPE}=" node-role.kubernetes.io/worker-
    echo
    echo "###########################################################################################"
    oc get machinesets.m -A
    oc get machines.m -A
    oc get nodes -l node-role.kubernetes.io/${MACHINESET_TYPE}
    echo "###########################################################################################"
}

function create_machineconfigpool()
{
  #MACHINESET_TYPE -- infra or workload machineset
  MACHINESET_TYPE=$1
  MACHINESET_TYPE=$(echo $MACHINESET_TYPE | tr -s "[A-Z]" "[a-z]")
  MACHINESET_TYPE=${MACHINESET_TYPE:-infra}
  echo "MACHINESET_TYPE is $MACHINESET_TYPE in create_machineconfigpool"
  # Create infra machineconfigpool
  if [[ $MACHINESET_TYPE == "infra" ]];then
      oc apply -f- <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: infra
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,infra]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/infra: ""
EOF
 elif [[ $MACHINESET_TYPE == "workload" ]];then
      oc apply -f- <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: workload
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,workload]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/workload: ""
EOF
 else
     echo "Invalid machineset type, should be [infra] or [workload]"
 fi
}


######################################################################################
#                                                                                    #
#                       Add Infra and Workload Entrypoint                            #
#                                                                                    #
######################################################################################

#The Following ENV variable can be override by SET_ENV_BY_PLATFORM=custom
#If SET_ENV_BY_PLATFORM=custom, the following ENV variables can be configured, below are some examples.
#If SET_ENV_BY_PLATFORM=custom and the following ENV variables are not configured, will use the same cpu/ram/volumesize with worker nodes.
#If SET_ENV_BY_PLATFORM is not set to custom, the following ENV variables can not be configured, will use the default settings in the script.
######################################################################################
#The INSTANCE_TYPE variable can be used for aws,gcp,azure,alicloud,  openstack and ibmcloud
#-------------------------------------------------------------------------------------
#           OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m6g.2xlarge
#           OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=m6g.8xlarge
#-------------------------------------------------------------------------------------

#The VOLUME_SIZE variable can be used for aws,gcp,azure,alicloud, can not used for openstack and ibmcloud
#-------------------------------------------------------------------------------------
#           OPENSHIFT_INFRA_NODE_VOLUME_SIZE=500
#           OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
#-------------------------------------------------------------------------------------

#The following variable can be used for vsphere
#-------------------------------------------------------------------------------------
#          OPENSHIFT_INFRA_NODE_VOLUME_SIZE=120
#          OPENSHIFT_INFRA_NODE_CPU_COUNT=48
#          OPENSHIFT_INFRA_NODE_MEMORY_SIZE=196608
#          OPENSHIFT_INFRA_NODE_CPU_CORE_PER_SOCKET_COUNT=2
#          OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
#          OPENSHIFT_WORKLOAD_NODE_CPU_COUNT=32
#          OPENSHIFT_WORKLOAD_NODE_MEMORY_SIZE=131072
#          OPENSHIFT_WORKLOAD_NODE_CPU_CORE_PER_SOCKET_COUNT=2
#-------------------------------------------------------------------------------------

#The following variable can be used for nutanix
#-------------------------------------------------------------------------------------
#           OPENSHIFT_INFRA_NODE_INSTANCE_VCPU=16
#           OPENSHIFT_INFRA_NODE_INSTANCE_MEMORYSIZE=64Gi
#           OPENSHIFT_WORKLOAD_NODE_INSTANCE_VCPU=16
#           OPENSHIFT_WORKLOAD_NODE_INSTANCE_MEMORYSIZE=64Gi
#-------------------------------------------------------------------------------------

#IF_INSTALL_INFRA_WORKLOAD=true/false
if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, can not continue."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

IF_INSTALL_INFRA_WORKLOAD=${IF_INSTALL_INFRA_WORKLOAD:=true}
if [[ ${IF_INSTALL_INFRA_WORKLOAD} != "true" ]];then
   echo "No need to install infra and workload for this OCP cluster"
   exit 0
fi

# Download jq
if [ ! -d /tmp/bin ];then
  mkdir /tmp/bin
  export PATH=$PATH:/tmp/bin
  curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
  chmod ug+x /tmp/bin/jq
fi

#Get Basic Infrastructue Architecture Info
node_arch=$(oc get nodes -ojsonpath='{.items[*].status.nodeInfo.architecture}')
platform_type=$(oc get infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')
node_arch=$(echo $node_arch | tr -s " " "\n"| sort -u)
all_machinesets=$(oc -n openshift-machine-api get machinesets.m -ojsonpath='{.items[*].metadata.name}{"\n"}')
machineset_list=$(echo $all_machinesets | tr -s ' ' '\n'| sort -u| grep -v -i -E "infra|workload|win"| head -n3)
machineset_count=$(echo $all_machinesets | tr -s ' ' '\n'| sort -u| grep -v -i -E "infra|workload|win"| head -n3 |wc -l)
total_worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker= -oname|wc -l)

scale_type=""
#Currently only support AWS reference to ROSA settings
if [[ $total_worker_nodes -ge 100 ]];then
	scale_type=medium
elif [[ $total_worker_nodes -ge 25 && $total_worker_nodes -lt 100 ]];then
	scale_type=small
elif [[ $total_worker_nodes -ge 1 && $total_worker_nodes -lt 25 ]];then
	scale_type=extrasmall
fi

######################################################################################
#             CHANGE BELOW VARIABLE IF YOU WANT TO SET DIFFERENT VALUE               #
######################################################################################
SET_ENV_BY_PLATFORM=${SET_ENV_BY_PLATFORM:=$platform_type}
echo SET_ENV_BY_PLATFORM is $SET_ENV_BY_PLATFORM
case ${SET_ENV_BY_PLATFORM} in
	aws)
     #ARM64 Architecture:
	   if [[ $node_arch == "arm64" ]];then
	      if [[ ${scale_type} == "medium" ]];then
                OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=m6g.4xlarge
                OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m6g.4xlarge
	      elif [[ ${scale_type} == "small" ]];then
                OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=m6g.2xlarge
                OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m6g.2xlarge
	      elif [[ ${scale_type} == "extrasmall" ]];then
                OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=m6g.xlarge
                OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m6g.xlarge
	      fi
	   else
	      if [[ ${scale_type} == "medium" ]];then
              #AMD/Standard Architecture:
                OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=r5.4xlarge
                OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m5.4xlarge
	      elif [[ ${scale_type} == "small" ]];then
                OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=r5.2xlarge
                OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m5.2xlarge
	      elif [[ ${scale_type} == "extrasmall" ]];then
                OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=r5.xlarge
                OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=m5.xlarge
	      fi
           fi
           #Both Architectures also need:
           OPENSHIFT_INFRA_NODE_VOLUME_TYPE=gp3
           OPENSHIFT_INFRA_NODE_VOLUME_SIZE=500
           OPENSHIFT_INFRA_NODE_VOLUME_IOPS=3000
           OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE=gp3
           OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
           OPENSHIFT_WORKLOAD_NODE_VOLUME_IOPS=3000
             ;;
	gcp)
          if [[ $node_arch == "arm64" ]];then
            OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=t2a-standard-16
            OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=t2a-standard-32
            OPENSHIFT_INFRA_NODE_VOLUME_TYPE=pd-ssd
          else
            OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=n1-standard-16
            OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=n1-standard-32
            OPENSHIFT_INFRA_NODE_VOLUME_TYPE=pd-ssd
          fi
	        OPENSHIFT_INFRA_NODE_VOLUME_SIZE=100

          OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE=pd-ssd
          OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
          ;;
	ibmcloud)
	   OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=bx2d-48x192
	   OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=bx2-32x128
             ;;
    	openstack)
           OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=ci.m1.xlarge
	   OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=ci.m1.xlarge
             ;;
	alibabacloud)
	   OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=ecs.g6.13xlarge
	   OPENSHIFT_INFRA_NODE_VOLUME_SIZE=100
	   OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=ecs.g6.8xlarge
	   OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
             ;;

	azure)
      #Azure use VM_SIZE as instance type, to unify variable, define all to INSTANCE_TYPE
      #ARM64 Architecture:
      if [[ $node_arch == "arm64" ]];then
          OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=Standard_D16ps_v5
          OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=Standard_D32ps_v5
      else 
          OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=Standard_D16s_v3
          OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=Standard_D32s_v3
      fi
            
        OPENSHIFT_INFRA_NODE_VOLUME_TYPE=Premium_LRS
        OPENSHIFT_INFRA_NODE_VOLUME_SIZE=128
        OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE=Premium_LRS
        OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
             ;;
	vsphere)
	   OPENSHIFT_INFRA_NODE_VOLUME_SIZE=120
	   OPENSHIFT_INFRA_NODE_CPU_COUNT=48
	   OPENSHIFT_INFRA_NODE_MEMORY_SIZE=196608
	   OPENSHIFT_INFRA_NODE_CPU_CORE_PER_SOCKET_COUNT=2
	   OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=500
	   OPENSHIFT_WORKLOAD_NODE_CPU_COUNT=32
	   OPENSHIFT_WORKLOAD_NODE_MEMORY_SIZE=131072
	   OPENSHIFT_WORKLOAD_NODE_CPU_CORE_PER_SOCKET_COUNT=2
             ;;
        nutanix)
	   #nutanix use VM_SIZE as instance type, to uniform variable, define all to INSTANCE_TYPE
           OPENSHIFT_INFRA_NODE_INSTANCE_VCPU=16
	   OPENSHIFT_INFRA_NODE_INSTANCE_MEMORYSIZE=64Gi
	   OPENSHIFT_WORKLOAD_NODE_INSTANCE_VCPU=16
	   OPENSHIFT_WORKLOAD_NODE_INSTANCE_MEMORYSIZE=64Gi
	   ;;
        custom)
	  ;;
	    
	 *)
	   echo -e "Un-supported infrastructure cluster detected. \nyou can specify SET_ENV_BY_PLATFORM=custom to override default value "
	   exit 1
esac

#Create infra and workload machineconfigpool
create_machineconfigpool infra

if [[ $IF_CREATE_WORKLOAD_NODE == "true" ]];then
  create_machineconfigpool workload
fi
#Set default value to none if no specified value, using cpu and ram of worker nodes to create machineset
#This also used for some property don't exist in a certain cloud provider, but need to pass correct parameter for create_machineset
OPENSHIFT_INFRA_NODE_INSTANCE_TYPE=${OPENSHIFT_INFRA_NODE_INSTANCE_TYPE:-none}
OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE=${OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE:-none}
OPENSHIFT_INFRA_NODE_VOLUME_IOPS=${OPENSHIFT_INFRA_NODE_VOLUME_IOPS:-none}
OPENSHIFT_INFRA_NODE_VOLUME_TYPE=${OPENSHIFT_INFRA_NODE_VOLUME_TYPE:-none}
OPENSHIFT_INFRA_NODE_VOLUME_SIZE=${OPENSHIFT_INFRA_NODE_VOLUME_SIZE:-none}
OPENSHIFT_WORKLOAD_NODE_VOLUME_IOPS=${OPENSHIFT_WORKLOAD_NODE_VOLUME_IOPS:-none}
OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE=${OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE:-none}
OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE=${OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE:-none}

#Usage of create_machineset
#create_machineset REF_MACHINESET_NAME NODE_REPLICAS(1) MACHINESET_TYPE(infra/workload) NODE_INSTANCE_TYPE(r5.4xlarge) VOLUME_TYPE(gp3) VOLUME_SIZE(50) VOLUME_IOPS(3000)
#Scale machineset to 3 replicas when only one machineset was found
IF_CREATE_WORKLOAD_NODE=${IF_CREATE_WORKLOAD_NODE:=false}
if [[ $machineset_count -eq 1 && -n $machineset_list ]];then

       machineset=$machineset_list
       create_machineset -m $machineset -r 3 -t infra -x $OPENSHIFT_INFRA_NODE_INSTANCE_TYPE -u $OPENSHIFT_INFRA_NODE_VOLUME_TYPE -v $OPENSHIFT_INFRA_NODE_VOLUME_SIZE -w $OPENSHIFT_INFRA_NODE_VOLUME_IOPS
     if [[ $IF_CREATE_WORKLOAD_NODE == "true" ]];then
       create_machineset -m $machineset -r 1 -t workload -x $OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE -u $OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE -v $OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE -w $OPENSHIFT_WORKLOAD_NODE_VOLUME_IOPS
     fi
elif [[ $machineset_count -eq 2 ]];then

       #The first AZ machineset will scale 2 infra replicas and 1 workload replicas
       machineset=$(echo $machineset_list | awk '{print $1}')
       create_machineset -m $machineset -r 2 -t infra -x $OPENSHIFT_INFRA_NODE_INSTANCE_TYPE -u $OPENSHIFT_INFRA_NODE_VOLUME_TYPE -v $OPENSHIFT_INFRA_NODE_VOLUME_SIZE -w $OPENSHIFT_INFRA_NODE_VOLUME_IOPS
     if [[ $IF_CREATE_WORKLOAD_NODE == "true" ]];then
       create_machineset -m $machineset -r 1 -t workload -x $OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE -u $OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE -v $OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE -w $OPENSHIFT_WORKLOAD_NODE_VOLUME_IOPS
     fi
       #The Second AZ machineset will scale 1 infra replicas 
       machineset=$(echo $machineset_list | awk '{print $2}')
       create_machineset -m $machineset -r 1 -t infra -x $OPENSHIFT_INFRA_NODE_INSTANCE_TYPE -u $OPENSHIFT_INFRA_NODE_VOLUME_TYPE -v $OPENSHIFT_INFRA_NODE_VOLUME_SIZE -w $OPENSHIFT_INFRA_NODE_VOLUME_IOPS

elif [[ $machineset_count -eq 3 ]];then

    for machineset in $machineset_list
    do
       create_machineset -m $machineset -r 1 -t infra -x $OPENSHIFT_INFRA_NODE_INSTANCE_TYPE -u $OPENSHIFT_INFRA_NODE_VOLUME_TYPE -v $OPENSHIFT_INFRA_NODE_VOLUME_SIZE -w $OPENSHIFT_INFRA_NODE_VOLUME_IOPS
    done
     if [[ $IF_CREATE_WORKLOAD_NODE == "true" ]];then
       machineset=$(echo $machineset_list | awk '{print $1}')
       create_machineset -m $machineset -r 1 -t workload -x $OPENSHIFT_WORKLOAD_NODE_INSTANCE_TYPE -u $OPENSHIFT_WORKLOAD_NODE_VOLUME_TYPE -v $OPENSHIFT_WORKLOAD_NODE_VOLUME_SIZE -w $OPENSHIFT_WORKLOAD_NODE_VOLUME_IOPS
     fi
else
       echo "No machineset was found or abnormal machineset"
fi

