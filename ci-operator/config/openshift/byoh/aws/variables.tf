# Instance name for the newly created Windows VM
variable winc_instance_name {
    type = string
}
# VM's image ami to used for the byoh instance
variable winc_worker_ami {
    type = string
}
# Hostname for one of the already existing cluster VM nodes
# You can get this info with: oc get nodes -l node-role.kubernetes.io/worker --no-headers
variable winc_machine_hostname {
    type = string
}
# New instance type
variable winc_instance_type {
    type = string
    default = "m5a.large"
}
# AWS Region
variable winc_region {
    type = string
}

# Number of BYOH worker instances
variable winc_number_workers {
    type = number
    default = 2
}

# Cluster name used to tag the AWS BYOH instance
# Context: https://bugzilla.redhat.com/show_bug.cgi?id=2078913
variable winc_cluster_name {
    type = string
}
