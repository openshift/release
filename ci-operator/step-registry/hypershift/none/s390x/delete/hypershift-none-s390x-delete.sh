# Delete the zVSI 
deletezVSI() {
    echo "Intiating the deletion of zVSI"
    echo "Logging into the IBM Cloud"
    ibmcloud login --apikey $IC_APIKEY
    ibmcloud target -r $region -g $resource_group
    echo "Triggering the instance deletion on IBM Cloud"
    ibmcloud is instance-delete $vsi_name
}