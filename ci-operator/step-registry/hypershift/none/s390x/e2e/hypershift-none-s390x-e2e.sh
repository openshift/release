# Create Z VSI
createzVSI() {
  echo "Intiating the creation of zVSI"
  echo "Logging into the IBM Cloud"
  ibmcloud login --apikey $IC_APIKEY
  echo "Triggering the instance creation on IBM Cloud"
  ibmcloud is instance-create $vsi_name $vpc_name $region $vsi_profile $subnet --image $image_name --keys $ssh_key_name
}