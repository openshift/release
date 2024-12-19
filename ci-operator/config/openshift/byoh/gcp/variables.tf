# Instance name for the newly created Windows VM
variable winc_instance_name {
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
    default = "n1-standard-4"
}

variable winc_project {
    type = string
    default = "openshift-qe"
}

variable winc_region {
    type = string
    default = "us-central"
}

variable winc_zone {
   type = string
   default = "us-central1-a" 
}

variable winc_win_version {
  type = string
  default = "windows-2022-core"
}

# Number of BYOH worker instances
variable winc_number_workers {
    type = number
    default = 2
}
