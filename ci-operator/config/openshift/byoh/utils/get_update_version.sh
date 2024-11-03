SKU_OFFER="WindowsServer"
SKU_PUBLISHER="MicrosoftWindowsServer"
SKU="2019-Datacenter"
location=$(az group show --resource-group $RG | jq '.location' | tr -d '"')
az vm image list -l $location -f $SKU_OFFER -p $SKU_PUBLISHER --sku $SKU --all --query "[?sku=='${SKU}'].version" -o tsv | sort -u
